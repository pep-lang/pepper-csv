## Writing CSV: `Writer`, which writes records to a stream, and
## `write_all`, which writes records into text.

import io;
import "convert";
import "read";

## Writes CSV records to a stream.
##
## A field is quoted only when it must be: when it holds the delimiter, a
## `"`, `\r` or `\n`, or when it is a record's only field and empty (which
## would otherwise be a blank line, which a reader skips). A `"` inside a
## quoted field is doubled. What it writes, `Reader` reads back as it was.
##
## @example
##     import csv;
##     import io;
##
##     main(): int {
##         var out = io.ByteWriter();
##         var writer = csv.Writer(out);
##         writer.write_row(["name", "note"]);
##         writer.write_row(["ada", "says \"hi\""]);
##         assert(out.bytes == "name,note\nada,\"says \"\"hi\"\"\"\n".bytes(), "quoted where needed");
##         return 0;
##     }
export struct Writer {
    # The stream written to.
    var _sink: io.Writer;
    # The text between fields, and after each record.
    var _delimiter: String;
    var _line_ending: String;
    # Whether `write` has written its header record.
    var _wrote_header: bool;

    ## Makes a writer of records to `sink`.
    ##
    ## @param sink the stream to write, such as an `io.File` or an
    ##   `io.ByteWriter`
    ## @param delimiter the one-byte text between fields: `","`, `"\t"`, `";"`
    ## @param line_ending the text after each record: `"\n"`, or `"\r\n"` as
    ##   RFC 4180 says
    ## @panics if `delimiter` is not one byte, or is `"`, `\r` or `\n`
    ##   ("csv: the delimiter must be one byte other than '\"', '\\r' and '\\n'")
    construct(sink: io.Writer, delimiter: String = ",", line_ending: String = "\n") {
        assert(_csv_valid_delimiter(delimiter), "csv: the delimiter must be one byte other than '\"', '\\r' and '\\n'");
        _sink = sink;
        _delimiter = delimiter;
        _line_ending = line_ending;
    }

    ## Writes one record.
    ##
    ## @param fields the record's fields
    ## @returns an Ok result once the record is written; an error when the
    ##   stream fails
    write_row(fields: Array<String>): io.IoResult<void> {
        return _sink.write_all(_csv_record_text(fields, _delimiter, _line_ending).bytes());
    }

    ## Writes `value`, a struct, as a record of its public properties, in
    ## the order they are declared. The first call writes a header record of
    ## their names first.
    ##
    ## Properties convert as `json.to_json` converts them, with the
    ## `serialize` attributes: `[Name("column")]` names a column and
    ## `[Ignore]` leaves a property out. A string is written as it is, an
    ## empty `Optional` as an empty field, and anything else as its JSON
    ## text (`42`, `true`), so `decode` reads it back.
    ##
    ## @typeParam T the struct to write
    ## @param value the value to write
    ## @returns an Ok result once the record is written; an error when the
    ##   stream fails
    write<T>(value: T): Result<void, io.IoError> {
        var members = _csv_fields(value);
        if (!_wrote_header) {
            _wrote_header = true;
            var names = Array<String>(members.count);
            for (var (key, member) in members) {
                names.append(key);
            }
            var wrote = write_row(names);
            if (wrote.is_err()) {
                return wrote;
            }
        }
        var fields = Array<String>(members.count);
        for (var (key, member) in members) {
            fields.append(_csv_text_of(member));
        }
        return write_row(fields);
    }
}

## Writes records as CSV text, as `Writer` writes them.
##
## @param rows the records, each an array of fields
## @param delimiter the one-byte text between fields
## @param line_ending the text after each record: `"\n"`, or `"\r\n"` as
##   RFC 4180 says
## @returns the CSV text
## @panics if `delimiter` is not one byte, or is `"`, `\r` or `\n`
## @example
##     import csv;
##
##     main(): int {
##         var text = csv.write_all([["a", "b"], ["1", "x\ny"]], line_ending = "\r\n");
##         assert(text == "a,b\r\n1,\"x\ny\"\r\n", "RFC 4180 line endings");
##         return 0;
##     }
export write_all(rows: Array<Array<String>>, delimiter: String = ",", line_ending: String = "\n"): String {
    assert(_csv_valid_delimiter(delimiter), "csv: the delimiter must be one byte other than '\"', '\\r' and '\\n'");
    var out = StringBuilder();
    for (var row in rows) {
        out.append(_csv_record_text(row, delimiter, line_ending));
    }
    return out.to_string();
}

# One record's text, its fields quoted where they must be.
_csv_record_text(fields: Array<String>, delimiter: String, line_ending: String): String {
    var out = StringBuilder();
    for (var index in 0..fields.count) {
        if (index > 0) {
            out.append(delimiter);
        }
        out.append(_csv_quoted(fields[index], delimiter, fields.count == 1));
    }
    out.append(line_ending);
    return out.to_string();
}

# `field` as a record holds it: quoted when it must be.
_csv_quoted(field: String, delimiter: String, alone: bool): String {
    var needs_quotes = field.contains(delimiter)
        || field.contains("\"")
        || field.contains("\n")
        || field.contains("\r")
        || (alone && field.is_empty);
    if (!needs_quotes) {
        return field;
    }
    return "\"" + field.replace("\"", "\"\"") + "\"";
}
