# The csv package's writer: quoting only where needed, delimiters, line
# endings, and round trips through the reader.

import csv;
import io;
import text;

[Test]
quotes_only_where_needed() {
    expect_equal(csv.write_all([["a", "b c", "1.5"]]), "a,b c,1.5\n");
    expect_equal(
        csv.write_all([["x,y", "say \"hi\"", "two\nlines", "cr\rhere"]]),
        "\"x,y\",\"say \"\"hi\"\"\",\"two\nlines\",\"cr\rhere\"\n"
    );
    expect_equal(csv.write_all([["", ""], [""]]), ",\n\"\"\n");
    expect_equal(csv.write_all(Array<Array<String>>()), "");
}

[Test]
writes_other_delimiters_and_line_endings() {
    expect_equal(csv.write_all([["a,b", "c\td"]], delimiter = "\t"), "a,b\t\"c\td\"\n");
    expect_equal(csv.write_all([["a", "b"], ["c", "d"]], line_ending = "\r\n"), "a,b\r\nc,d\r\n");
}

[Test]
writes_to_a_stream() {
    var out = io.ByteWriter();
    var writer = csv.Writer(out, delimiter = ";");
    expect_true(writer.write_row(["a", "b;c"]).is_ok());
    expect_true(writer.write_row(["1", "2"]).is_ok());
    expect_equal(text.Utf8.decode_lossy(out.bytes), "a;\"b;c\"\n1;2\n");
}

[Test]
round_trips_through_the_reader() {
    var rows = [["", "\"", "\"\""], ["a\r\nb", ",", "\u{FEFF}x"], [""], ["tail\r"]];
    for (var delimiter in [",", "\t", ";", "|"]) {
        for (var line_ending in ["\n", "\r\n"]) {
            var back = csv.parse(csv.write_all(rows, delimiter, line_ending), delimiter).value();
            expect_equal(back.count, rows.count);
            for (var index in 0..rows.count) {
                expect_equal(back[index].count, rows[index].count);
                for (var column in 0..rows[index].count) {
                    expect_equal(back[index][column], rows[index][column]);
                }
            }
        }
    }
}
