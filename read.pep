## Reading CSV: `Reader`, which reads records from a stream as they are
## asked for; `parse`, which reads a whole text; and `CsvError`, what they
## report when the text is not CSV.

import io;
import json;
import text;
import "convert";

## What reading reports when the text is not CSV, and what `Reader.read`
## and `decode` report when a field does not fit its property: what is
## wrong, and the line and column where it is.
##
## `to_string()` renders it like a compiler error:
## `people.csv:4:12: error: unterminated quoted field`.
export struct CsvError {
    ## What is wrong, worded like a compiler error (`expected ',' or a line
    ## break after the closing '"'`).
    var message: String;
    ## The path given to the reader, which names the text in `to_string()`;
    ## empty when none was given.
    var path: String;
    ## The line of the error, from 1; 0 for an error with no place in the
    ## text, such as a failed read of the stream.
    var line: ulong;
    ## The column of the error, from 1, counting bytes as clang does; 0
    ## when `line` is.
    var column: ulong;

    ## Creates an error.
    ##
    ## @param message what is wrong
    ## @param path the name of the text, or empty
    ## @param line the line of the error, from 1
    ## @param column the column of the error, from 1
    construct(message: String = "", path: String = "", line: ulong = 1, column: ulong = 1) {
        this.message = message;
        this.path = path;
        this.line = line;
        this.column = column;
    }

    ## Returns the error as a compiler prints one:
    ## `path:line:column: error: message`, without the `path:` when there
    ## is no path and without `line:column:` when `line` is 0.
    ##
    ## @returns the rendered error
    to_string(): String {
        if (line == 0) {
            if (path.is_empty) {
                return $"error: {message}";
            }
            return $"{path}: error: {message}";
        }
        if (path.is_empty) {
            return $"{line}:{column}: error: {message}";
        }
        return $"{path}:{line}:{column}: error: {message}";
    }
}

## Reads CSV records from a stream, one at a time, so a large file is never
## held whole.
##
## The format is RFC 4180's, read strictly: a field that holds the
## delimiter, a `"` or a line break is quoted, and a `"` inside it is
## doubled (`"say ""hi"""`). A record ends at `\n` or `\r\n`; a `\r` on its
## own is part of a field. A UTF-8 byte-order mark at the start is skipped,
## and blank lines are skipped, so a file that ends with a line break has no
## empty record after it. Anything else is an error that names its line
## and column: a `"` inside an unquoted field, text after a closing quote,
## a quoted field that never closes, or a field that is not UTF-8. The
## first error ends the reading.
##
## Records may have different numbers of fields; `read` is what checks
## them against the header.
##
## @example
##     import csv;
##     import io;
##
##     main(): int {
##         var reader = csv.Reader(io.ByteReader("name,note\nada,\"says \"\"hi\"\"\"\n".bytes()));
##         for (var record in reader) {
##             if (record.is_err()) {
##                 print(record.error().to_string());
##                 return 1;
##             }
##             print(record.value()[1]);   # note, then: says "hi"
##         }
##         return 0;
##     }
export struct Reader {
    ## The name of the text, which errors carry; empty when none was given.
    var path: String;
    ## The names of the header record, which the first `read` reads; empty
    ## until then.
    var header: Array<String>;
    ## The line of the first field of the record read last, from 1.
    var line: ulong;

    # The stream being read.
    var _source: io.Reader;
    # The byte between fields.
    var _delimiter: u8;
    # The most bytes one record's fields may hold together.
    var _max_record_bytes: ulong;
    # Bytes read from `_source`, and the index of the next one to look at.
    var _chunk: u8[];
    var _position: ulong;
    # Whether `_source` has nothing more to give (at its end, or failed).
    var _ended: bool;
    # Where the next byte is in the text.
    var _next_line: ulong;
    var _next_column: ulong;
    # Whether the byte-order mark has been looked for.
    var _started: bool;
    # The bytes the fields of the current record hold so far.
    var _record_bytes: ulong;
    # The error that ended the reading.
    var _failure: CsvError?;
    # Where each field of the record read last starts.
    var _field_lines: Array<ulong>;
    var _field_columns: Array<ulong>;
    # The iteration's state: whether it has ended, whether `_value` holds
    # the current element, and the current element.
    var _iteration_ended: bool;
    var _has_value: bool;
    var _value: Result<Array<String>, CsvError>;

    ## Makes a reader of the records of `source`, from what it reads next.
    ##
    ## @param source the stream to read, such as an `io.File`, or an
    ##   `io.ByteReader` over text in memory
    ## @param delimiter the one-byte text between fields: `","`, `"\t"`, `";"`
    ## @param path the name of the text (a file name, say), which errors put
    ##   first
    ## @param max_record_bytes the most bytes one record's fields may hold;
    ##   a longer record is an error, so a quote that never closes cannot
    ##   fill memory
    ## @panics if `delimiter` is not one byte, or is `"`, `\r` or `\n`
    ##   ("csv: the delimiter must be one byte other than '\"', '\\r' and '\\n'")
    construct(source: io.Reader, delimiter: String = ",", path: String = "", max_record_bytes: ulong = 16777216) {
        assert(_csv_valid_delimiter(delimiter), "csv: the delimiter must be one byte other than '\"', '\\r' and '\\n'");
        this.path = path;
        header = Array<String>();
        _source = source;
        _delimiter = delimiter.byte_at(0);
        _max_record_bytes = max_record_bytes;
        _chunk = Array<u8>();
        _next_line = 1;
        _next_column = 1;
        _failure = Optional<CsvError>.Empty;
        _field_lines = Array<ulong>();
        _field_columns = Array<ulong>();
        _value = Result<Array<String>, CsvError>.ok(Array<String>());
    }

    ## Reads the next record.
    ##
    ## @returns the record's fields, none at the end of the stream, or the
    ##   error that ends the reading (which every later call returns too)
    read_row(): Result<Array<String>?, CsvError> {
        if (!_started) {
            _started = true;
            _skip_byte_order_mark();
        }
        _skip_blank_lines();
        if (_failure.is_value()) {
            return Result<Array<String>?, CsvError>.err(_failure.value());
        }
        if (!_fill(1)) {
            return Result<Array<String>?, CsvError>.ok(Optional<Array<String>>.Empty);
        }
        line = _next_line;
        _record_bytes = 0;
        _field_lines.clear();
        _field_columns.clear();
        var fields = Array<String>();
        var bytes = Array<u8>();
        var ended = false;
        while (!ended) {
            _field_lines.append(_next_line);
            _field_columns.append(_next_column);
            bytes.clear();
            ended = _read_field(bytes);
            if (_failure.is_value()) {
                return Result<Array<String>?, CsvError>.err(_failure.value());
            }
            var decoded = text.Utf8.decode(bytes);
            if (decoded.is_empty()) {
                return Result<Array<String>?, CsvError>.err(
                    _fail("field is not valid UTF-8", _field_lines.last(), _field_columns.last())
                );
            }
            fields.append(decoded.value());
        }
        return Result<Array<String>?, CsvError>.ok(Optional<Array<String>>.Value(fields));
    }

    ## Reads the next record into a `T`, a struct, matching the header's
    ## names to its properties as `decode` does. The first call reads the
    ## header record first, into `header`.
    ##
    ## A column that names no property is skipped; the other `read` can
    ## reject it instead.
    ##
    ## @typeParam T the struct to read into
    ## @returns the value, none at the end of the stream, or the first
    ##   error, at the line and column of the field it is about
    read<T>(): Result<T?, CsvError> {
        # An overload rather than a default argument: pepper 0.9.2 resolves
        # a generic method's default in the caller's module. Both overloads
        # call `_read`: pepper 0.10.0 miscompiles one generic overload
        # calling the other (pep-lang/pepper#32).
        return _read<T>(json.UnknownKeys.Ignore);
    }

    ## Reads the next record into a `T`, as the other `read` does, with
    ## `unknown_keys` saying what to do with a column that names no
    ## property.
    ##
    ## @typeParam T the struct to read into
    ## @param unknown_keys what to do with a column that names no property
    ## @returns the value, none at the end of the stream, or the first
    ##   error, at the line and column of the field it is about
    read<T>(unknown_keys: json.UnknownKeys): Result<T?, CsvError> {
        return _read<T>(unknown_keys);
    }

    _read<T>(unknown_keys: json.UnknownKeys): Result<T?, CsvError> {
        if (header.is_empty) {
            var names = read_row();
            if (names.is_err()) {
                return Result<T?, CsvError>.err(names.error());
            }
            if (names.value().is_empty()) {
                return Result<T?, CsvError>.ok(Optional<T>.Empty);
            }
            var duplicate = _csv_duplicate(names.value().value());
            if (duplicate.is_value()) {
                var index = duplicate.value();
                return Result<T?, CsvError>.err(
                    _fail(
                        $"duplicate column '{names.value().value()[index]}'", _field_lines[index], _field_columns[index]
                    )
                );
            }
            header = names.value().value();
        }
        var row = read_row();
        if (row.is_err()) {
            return Result<T?, CsvError>.err(row.error());
        }
        if (row.value().is_empty()) {
            return Result<T?, CsvError>.ok(Optional<T>.Empty);
        }
        var fields = row.value().value();
        if (fields.count != header.count) {
            return Result<T?, CsvError>.err(
                CsvError(
                    $"expected {header.count} fields, as the header has, but found {fields.count}",
                    path,
                    _field_lines[0],
                    _field_columns[0]
                )
            );
        }
        var converted = _csv_from_row<T>(header, fields, unknown_keys);
        if (converted.is_ok()) {
            return Result<T?, CsvError>.ok(Optional<T>.Value(converted.value()));
        }
        var (index, message) = _csv_place(header, converted.error());
        return Result<T?, CsvError>.err(CsvError(message, path, _field_lines[index], _field_columns[index]));
    }

    ## Moves to the next record, so a `for` loop reads the records in turn.
    ##
    ## @returns true if there is a current element (a record, or the error
    ##   that ends the reading), false at the end of the stream
    next(): bool {
        _has_value = false;
        if (_iteration_ended) {
            return false;
        }
        var row = read_row();
        if (row.is_err()) {
            _iteration_ended = true;
            _value = Result<Array<String>, CsvError>.err(row.error());
            _has_value = true;
            return true;
        }
        if (row.value().is_empty()) {
            _iteration_ended = true;
            return false;
        }
        _value = Result<Array<String>, CsvError>.ok(row.value().value());
        _has_value = true;
        return true;
    }

    ## Returns the element the last successful `next()` moved to.
    ##
    ## @returns the current record, or the error that ended the reading
    ## @panics if `next()` was never called, or already returned false
    ##   ("csv.Reader.current() without a record")
    current(): Result<Array<String>, CsvError> {
        assert(_has_value, "csv.Reader.current() without a record");
        return _value;
    }

    # Reads one field's bytes into `bytes` and the delimiter or line break
    # after it, and says whether the record ended. An error sets `_failure`.
    _read_field(bytes: u8[]): bool {
        if (_fill(1) && _chunk[_position] == '"') {
            return _read_quoted(bytes);
        }
        while (_fill(1)) {
            var byte = _chunk[_position];
            if (byte == _delimiter) {
                _take();
                return false;
            }
            if (_at_line_break()) {
                return true;
            }
            if (byte == '"') {
                _fail("'\"' in an unquoted field; quote the field and double the '\"'", _next_line, _next_column);
                return true;
            }
            _take();
            if (!_keep(bytes, byte)) {
                return true;
            }
        }
        return true;
    }

    # Reads a quoted field, from its opening quote, as `_read_field` does.
    _read_quoted(bytes: u8[]): bool {
        var open_line = _next_line;
        var open_column = _next_column;
        _take();
        while (true) {
            if (!_fill(1)) {
                if (_failure.is_empty()) {
                    _fail("unterminated quoted field", open_line, open_column);
                }
                return true;
            }
            var byte = _chunk[_position];
            _take();
            if (byte == '"') {
                if (!_fill(1)) {
                    return true;
                }
                if (_chunk[_position] != '"') {
                    return _after_closing_quote();
                }
                _take();
            }
            if (!_keep(bytes, byte)) {
                return true;
            }
        }
        return true;
    }

    # Reads what must follow a closing quote: the delimiter or a line break.
    _after_closing_quote(): bool {
        if (_chunk[_position] == _delimiter) {
            _take();
            return false;
        }
        if (_at_line_break()) {
            return true;
        }
        _fail(
            $"expected '{_csv_delimiter_name(_delimiter)}' or a line break after the closing '\"'",
            _next_line,
            _next_column
        );
        return true;
    }

    # Whether a line break starts at the next byte; takes it if so.
    _at_line_break(): bool {
        var byte = _chunk[_position];
        if (byte == '\n') {
            _take();
            return true;
        }
        if (byte == '\r' && _fill(2) && _chunk[_position + 1] == '\n') {
            _take();
            _take();
            return true;
        }
        return false;
    }

    # Appends `byte` to a field, unless the record would pass its limit.
    _keep(bytes: u8[], byte: u8): bool {
        _record_bytes += 1;
        if (_record_bytes > _max_record_bytes) {
            _fail($"record is longer than {_max_record_bytes} bytes", line, 1);
            return false;
        }
        bytes.append(byte);
        return true;
    }

    _skip_byte_order_mark() {
        if (_fill(3) && _chunk[_position] == 0xEF && _chunk[_position + 1] == 0xBB && _chunk[_position + 2] == 0xBF) {
            _position += 3;
        }
    }

    _skip_blank_lines() {
        while (_fill(1) && _at_line_break()) {}
    }

    # Moves past the next byte, keeping the line and column.
    _take() {
        var byte = _chunk[_position];
        _position += 1;
        if (byte == '\n') {
            _next_line += 1;
            _next_column = 1;
            return;
        }
        _next_column += 1;
    }

    # Whether `count` bytes are ready from `_position`, reading more when
    # needed. A failed read sets `_failure`.
    _fill(count: ulong): bool {
        while (_chunk.count - _position < count) {
            if (_ended) {
                return false;
            }
            if (_position == _chunk.count) {
                _chunk.clear();
                _position = 0;
            }
            var read = _source.read(_chunk, 65536);
            if (read.is_err()) {
                _ended = true;
                _failure = Optional<CsvError>.Value(
                    CsvError($"cannot read the stream: {read.error().message}", path, 0, 0)
                );
                return false;
            }
            if (read.value() == 0) {
                _ended = true;
                return false;
            }
        }
        return true;
    }

    # Ends the reading with an error at `at_line`:`at_column`.
    _fail(message: String, at_line: ulong, at_column: ulong): CsvError {
        var error = CsvError(message, path, at_line, at_column);
        _failure = Optional<CsvError>.Value(error);
        _ended = true;
        _chunk.clear();
        _position = 0;
        return error;
    }
}

extend Reader with Iterator<Result<Array<String>, CsvError>>;

## Reads every record of a CSV text, as `Reader` reads them.
##
## @param text the CSV text
## @param delimiter the one-byte text between fields: `","`, `"\t"`, `";"`
## @param path the name of the text (a file name, say), which errors put
##   first
## @returns the records in order (none for empty text), or the first error
## @panics if `delimiter` is not one byte, or is `"`, `\r` or `\n`
## @example
##     import csv;
##
##     main(): int {
##         var rows = csv.parse("a;b\n1;\"x;y\"\n", delimiter = ";").value();
##         assert(rows[1][1] == "x;y", "a quoted delimiter");
##         var bad = csv.parse("a,\"b\n", path = "bad.csv");
##         assert(bad.error().to_string() == "bad.csv:1:3: error: unterminated quoted field", "where");
##         return 0;
##     }
export parse(text: String, delimiter: String = ",", path: String = ""): Result<Array<Array<String>>, CsvError> {
    var rows = Array<Array<String>>();
    for (var record in Reader(io.ByteReader(text.bytes()), delimiter, path)) {
        if (record.is_err()) {
            return Result<Array<Array<String>>, CsvError>.err(record.error());
        }
        rows.append(record.value());
    }
    return Result<Array<Array<String>>, CsvError>.ok(rows);
}

# Whether `delimiter` can separate fields.
_csv_valid_delimiter(delimiter: String): bool {
    return delimiter.size == 1 && delimiter != "\"" && delimiter != "\r" && delimiter != "\n";
}

# The delimiter as an error message shows it.
_csv_delimiter_name(delimiter: u8): String {
    if (delimiter == '\t') {
        return "\\t";
    }
    var bytes = Array<u8>();
    bytes.append(delimiter);
    return text.Utf8.decode_lossy(bytes);
}

# The index of the first name that an earlier one repeats.
_csv_duplicate(names: Array<String>): ulong? {
    var seen = HashSet<String>();
    for (var index in 0..names.count) {
        if (!seen.insert(names[index])) {
            return Optional<ulong>.Value(index);
        }
    }
    return Optional<ulong>.Empty;
}
