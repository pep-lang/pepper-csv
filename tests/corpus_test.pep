# The csv package against its corpus of tricky files, read from disk
# through `io.File`: each `testdata/valid` file reads as the records its
# `.json` file lists and writes back to text that reads the same, and each
# `testdata/invalid` file fails with the error its `.error` file holds.
# `tests/run.sh` runs the tests from the repository's root.

import csv;
import io;
import json;

const TESTDATA = "tests/testdata";

# Every record of the file at `name` under `folder`, or the first error.
read_file(folder: String, name: String): Result<Array<Array<String>>, csv.CsvError> {
    var file = io.File.open(io.Path(TESTDATA).join(folder).join(name)).value();
    var delimiter = name.ends_with(".tsv") ? "\t" : ",";
    var rows = Array<Array<String>>();
    for (var record in csv.Reader(file, delimiter, path = $"{folder}/{name}")) {
        if (record.is_err()) {
            return Result<Array<Array<String>>, csv.CsvError>.err(record.error());
        }
        rows.append(record.value());
    }
    return Result<Array<Array<String>>, csv.CsvError>.ok(rows);
}

# The files of `folder` with a name ending in one of `extensions`.
files_of(folder: String, extensions: Array<String>): Array<String> {
    var names = Array<String>();
    for (var entry in io.Directory.open(io.Path(TESTDATA).join(folder)).value().entries().value()) {
        for (var extension in extensions) {
            if (entry.name.ends_with(extension)) {
                names.append(entry.name);
            }
        }
    }
    expect_true(names.count > 0);
    return names;
}

# Whether `rows` holds exactly the records `expected`, a JSON array of
# arrays of strings, lists.
same_rows(rows: Array<Array<String>>, expected: json.JsonValue): bool {
    var records = expected.as_array().value();
    if (records.count != rows.count) {
        return false;
    }
    for (var index in 0..rows.count) {
        var fields = records[index].as_array().value();
        if (fields.count != rows[index].count) {
            return false;
        }
        for (var column in 0..fields.count) {
            if (fields[column].as_string().value() != rows[index][column]) {
                return false;
            }
        }
    }
    return true;
}

[Test]
reads_the_valid_files() {
    for (var name in files_of("valid", [".csv", ".tsv"])) {
        var rows = read_file("valid", name);
        if (rows.is_err()) {
            print(rows.error().to_string());
        }
        expect_true(rows.is_ok());
        var stem = name.substr_bytes(0, name.size - 4);
        var expected = json.parse(io.File.read_to_string(io.Path(TESTDATA).join("valid").join(stem + ".json")).value());
        if (!same_rows(rows.value(), expected.value())) {
            print($"{name} does not read as {stem}.json says");
        }
        expect_true(same_rows(rows.value(), expected.value()));

        var delimiter = name.ends_with(".tsv") ? "\t" : ",";
        var again = csv.parse(csv.write_all(rows.value(), delimiter), delimiter);
        expect_true(same_rows(again.value(), expected.value()));
    }
}

[Test]
rejects_the_invalid_files() {
    for (var name in files_of("invalid", [".csv"])) {
        var rows = read_file("invalid", name);
        expect_true(rows.is_err());
        var stem = name.substr_bytes(0, name.size - 4);
        var expected = io.File.read_to_string(io.Path(TESTDATA).join("invalid").join(stem + ".error")).value().trim();
        expect_equal(rows.error().to_string(), expected);
    }
}
