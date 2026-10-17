# pepper-csv

CSV (RFC 4180) for [Pepper](https://github.com/justinboswell/pepper)
(issue justinboswell/pepper#948): read records from a stream or a text,
write them back, and convert structs to records and back. It has the same
shape as the runtime's `json` and `toml` modules and the `yaml` package.

One module, **`csv`**:

- **`csv.Reader(source)`** reads records from any `io.Reader` (a file, a
  socket, an `io.ByteReader`) one at a time, so a large file is never held
  whole: `read_row()` gives the next record's fields, and a `for` loop over
  the reader gives each record as a `Result`. **`csv.parse(text)`** reads a
  whole text.
- **`csv.Writer(sink)`** writes records to any `io.Writer` with
  `write_row(fields)`, quoting only the fields that need it;
  **`csv.write_all(rows)`** writes them into text.
- **`csv.decode<T>(text)`** and **`csv.encode(values)`** convert structs
  through reflection, the header record naming their properties, with the
  `serialize` attributes (`[Name("column")]`, `[Ignore]`, `[Required]`) as
  `json` reads them. **`Reader.read<T>()`** and **`Writer.write(value)`**
  do the same a record at a time.
- Each takes **`delimiter`** (`","` by default; `"\t"`, `";"` or any other
  byte), and the writers take **`line_ending`** (`"\n"` by default, or
  `"\r\n"` as RFC 4180 says).

```pepper
import csv;
import io;
import serialize;

struct Person {
    [Required]
    var name: String;
    var age: int;
    [Name("e-mail")]
    var email: String?;
}

main(): int {
    var file = io.File.open(io.Path("people.csv")).value();
    var reader = csv.Reader(file, path = "people.csv");
    while (true) {
        var person = reader.read<Person>();
        if (person.is_err()) {
            print(person.error().to_string());   # people.csv:LINE:COLUMN: error: ...
            return 1;
        }
        if (person.value().is_empty()) {
            break;
        }
        print(person.value().value().name);
    }

    var rows = csv.parse("a;b\n1;\"x;y\"\n", delimiter = ";").value();
    print(rows[1][1]);                                  # x;y
    print(csv.write_all([["say \"hi\"", "two\nlines"]]));   # "say ""hi""","two\nlines"
    return 0;
}
```

## What it reads

- **RFC 4180**, strictly: a quoted field may hold the delimiter, line
  breaks and doubled quotes (`"say ""hi"""`). A record ends at `\n` or
  `\r\n`; a `\r` on its own is part of a field. Fields are UTF-8.
- **Leniencies everyone expects**: a UTF-8 byte-order mark at the start is
  skipped; blank lines are skipped, so a file ending with a line break has
  no empty record after it; the last record needs no line break; records
  may have different numbers of fields (only `decode` and `read` require
  each to match the header).
- **Errors** are clang-style, at the line and column of the problem, and
  the first one ends the reading: `people.csv:2:3: error: unterminated
  quoted field`, `'"' in an unquoted field`, `expected ',' or a line break
  after the closing '"'`, `field is not valid UTF-8`. Conversion errors
  name the column, at its field: `people.csv:2:5: error: column 'age':
  expected a number, found a string`.
- **Safe for untrusted text**: a record may not hold more than
  `max_record_bytes` (16 MiB by default), so a quote that never closes
  cannot fill memory.

## Struct conversion

- A `String` property takes its field as it is, even empty. For any other
  property an empty field is missing: the property keeps its default, an
  `Optional` is empty, and a `[Required]` property is an error. A
  non-empty `String?` takes the field as it is; any other property reads it
  as a JSON number or boolean, or else as a string, so an enum takes a
  case's name.
- The header may not name a column twice. A column that names no property
  is skipped, or with `unknown_keys = json.UnknownKeys.Reject` is an error.
- `encode` and `Writer.write` write a header of the properties' names,
  then each value: a string as it is, an empty `Optional` as an empty
  field, anything else as its JSON text. `encode` of no values is empty
  text, since there is nothing to take a header from.
- Conversion goes through `json.JsonValue`, so it shares `json`'s rules and
  messages; a compile error for a property it cannot convert says "to
  JSON".

## Limits

- Reading is strict only: there is no lenient mode for malformed files
  (an open question on #948, left out for safety and simplicity).
- A record's fields are plain strings: no type inference outside struct
  conversion, and no comment lines.
- A property that holds a struct, an array or a map is written as its JSON
  text and cannot be read back from a field.

## Using it

This repository is a package: `pep.toml` marks its root, and its root
`module.pep` is the `csv` module. Add it to a project under the name
`csv`:

```sh
pepper package add justinboswell/pepper-csv --name csv
```

which writes

```toml
[dependencies]
csv = { github = "justinboswell/pepper-csv" }
```

Without a project, put a folder named `csv` that holds (or links to) this
repository on the import path: `pepper build -I packages main.pep`.

## Tests

```sh
tests/run.sh path/to/pepper
```

runs the `[Test]` functions in `tests/` with `pepper test`, from the
repository's root: the reader (`read_test.pep`), the writer
(`write_test.pep`), struct conversion (`convert_test.pep`), and the corpus
(`corpus_test.pep`), which reads each file of `tests/testdata/valid` and
checks it against its `.json` file, writes it back and reads it again, and
checks that each file of `tests/testdata/invalid` fails with the error in
its `.error` file. A new tricky case is a new pair of files there.
