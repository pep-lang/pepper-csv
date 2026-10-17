# The csv package's reader: quoting, line endings, the byte-order mark,
# delimiters, streaming, the record size limit, and errors with their line
# and column.

import csv;
import io;

rows_of(source: String, delimiter: String = ","): Array<Array<String>> {
    var result = csv.parse(source, delimiter);
    if (result.is_err()) {
        print(result.error().to_string());
        panic("parse failed");
    }
    return result.value();
}

error_of(source: String): String {
    var result = csv.parse(source, path = "test.csv");
    expect_true(result.is_err());
    return result.error().to_string();
}

[Test]
reads_plain_records() {
    var rows = rows_of("a,b,c\n1,2,3\n");
    expect_equal(rows.count, 2);
    expect_equal(rows[0][2], "c");
    expect_equal(rows[1][0], "1");
    expect_equal(rows_of("").count, 0);
    expect_equal(rows_of("a,,\n")[0].count, 3);
    expect_equal(rows_of("a,")[0][1], "");
}

[Test]
reads_quoted_fields() {
    var rows = rows_of("\"a,b\",\"say \"\"hi\"\"\",\"line\nbreak\",\"\"\n");
    expect_equal(rows[0][0], "a,b");
    expect_equal(rows[0][1], "say \"hi\"");
    expect_equal(rows[0][2], "line\nbreak");
    expect_equal(rows[0][3], "");
    expect_equal(rows_of("\"crlf\r\ninside\"\r\n")[0][0], "crlf\r\ninside");
}

[Test]
reads_line_endings_and_blank_lines() {
    var rows = rows_of("a,b\r\n\r\n1,2\n\n3,4");
    expect_equal(rows.count, 3);
    expect_equal(rows[1][1], "2");
    expect_equal(rows[2][1], "4");
    expect_equal(rows_of("a\rb\n")[0][0], "a\rb");
}

[Test]
skips_the_byte_order_mark() {
    var rows = rows_of("\u{FEFF}name\nada\n");
    expect_equal(rows[0][0], "name");
    expect_equal(rows_of("x,\u{FEFF}\n")[0][1], "\u{FEFF}");
}

[Test]
reads_other_delimiters() {
    expect_equal(rows_of("a\tb\t\"c\td\"\n", "\t")[0][2], "c\td");
    expect_equal(rows_of("a;b,c\n", ";")[0][1], "b,c");
}

[Test]
reports_errors_where_they_are() {
    expect_equal(error_of("a,b\n1,\"2\n"), "test.csv:2:3: error: unterminated quoted field");
    expect_equal(
        error_of("a,b\n1,b\"c\n"), "test.csv:2:4: error: '\"' in an unquoted field; quote the field and double the '\"'"
    );
    expect_equal(error_of("\"a\"b\n"), "test.csv:1:4: error: expected ',' or a line break after the closing '\"'");
    var invalid = "a,".bytes();
    invalid.append(0xFF);
    var reader = csv.Reader(io.ByteReader(invalid), path = "test.csv");
    expect_equal(reader.read_row().error().to_string(), "test.csv:1:3: error: field is not valid UTF-8");
}

[Test]
stops_at_the_first_error() {
    var reader = csv.Reader(io.ByteReader("a\n\"b\n".bytes()));
    expect_equal(reader.read_row().value().value()[0], "a");
    expect_true(reader.read_row().is_err());
    expect_true(reader.read_row().is_err());
    var count = 0;
    for (var record in csv.Reader(io.ByteReader("a\nb\"\nc\n".bytes()))) {
        count += 1;
    }
    expect_equal(count, 2);
}

[Test]
limits_the_record_size() {
    var reader = csv.Reader(io.ByteReader("ok\n\"abcdefghij".bytes()), max_record_bytes = 4);
    expect_equal(reader.read_row().value().value()[0], "ok");
    expect_equal(reader.read_row().error().to_string(), "2:1: error: record is longer than 4 bytes");
}

# A stream that hands out one byte per read, so every quote, line break and
# byte-order mark falls across reads.
struct Trickle {
    var _data: u8[];
    var _position: ulong;

    construct(data: u8[]) {
        _data = data;
    }

    read(buffer: u8[], max: ulong): io.IoResult<ulong> {
        if (_position == _data.count) {
            return io.IoResult<ulong>.ok(0);
        }
        buffer.append(_data[_position]);
        _position += 1;
        return io.IoResult<ulong>.ok(1);
    }
}

extend Trickle with io.Reader;

[Test]
reads_a_stream_a_byte_at_a_time() {
    var source = "\u{FEFF}a,\"b\"\"c\"\r\n\"d\r\ne\",f\r\n";
    var reader = csv.Reader(Trickle(source.bytes()));
    var first = reader.read_row().value().value();
    expect_equal(first[0], "a");
    expect_equal(first[1], "b\"c");
    var second = reader.read_row().value().value();
    expect_equal(second[0], "d\r\ne");
    expect_equal(second[1], "f");
    expect_equal(reader.line, 2);
    expect_true(reader.read_row().value().is_empty());
}
