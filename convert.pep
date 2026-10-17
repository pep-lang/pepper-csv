## Struct conversion: `decode` reads CSV records into structs and `encode`
## writes structs as CSV records, through reflection, with no per-type code
## to write.
##
## A record is a struct; the header names its properties. Conversion goes
## through `json`'s, so the `serialize` attributes (`[Name]`, `[Ignore]`,
## `[Required]`) work as they do for `json` and `toml`.

import io;
import json;
import serialize;
import text;
import "read";
import "write";

## Reads every record of a CSV text into a `T`, a struct, matching the
## header record's names to its properties.
##
## A property takes its column from `[Name("column")]` when it has one, and
## is skipped when marked `[Ignore]`. A `String` property takes the field as
## it is, even empty. For any other property an empty field counts as
## missing, which leaves the property at its default, makes an `Optional`
## (`String?` included) empty, and is an error for a `[Required]` one;
## otherwise a `String?` takes the field as it is, and the rest read it as
## a JSON value (`42`, `2.5`, `true`) or, failing that, as a string, so an
## enum takes a case's name. A column that names no property is skipped, or with
## `unknown_keys = json.UnknownKeys.Reject` is an error.
##
## Every record must have as many fields as the header, and the header may
## not name a column twice.
##
## @typeParam T the struct to read into
## @param text the CSV text, its first record the header
## @param delimiter the one-byte text between fields: `","`, `"\t"`, `";"`
## @param path the name of the text (a file name, say), which errors put
##   first
## @param unknown_keys what to do with a column that names no property
## @returns the values in order, or the first error, at the line and column
##   of the field it is about
## @panics if `delimiter` is not one byte, or is `"`, `\r` or `\n`
## @example
##     import csv;
##     import serialize;
##
##     struct Person {
##         [Required]
##         var name: String;
##         var age: int;
##         [Name("e-mail")]
##         var email: String?;
##     }
##
##     main(): int {
##         var people = csv.decode<Person>("name,age,e-mail\nada,36,ada@example.com\nbob,,\n").value();
##         assert(people[0].age == 36, "a number");
##         assert(people[1].email.is_empty(), "an empty field");
##
##         var bad = csv.decode<Person>("name,age\nada,old\n", path = "people.csv");
##         assert(bad.error().to_string() == "people.csv:2:5: error: column 'age': expected a number, found a string", "where");
##         return 0;
##     }
export decode<T>(
    text: String, delimiter: String = ",", path: String = "", unknown_keys: json.UnknownKeys = json.UnknownKeys.Ignore
): Result<Array<T>, CsvError> {
    var reader = Reader(io.ByteReader(text.bytes()), delimiter, path);
    var values = Array<T>();
    while (true) {
        var value = reader.read<T>(unknown_keys);
        if (value.is_err()) {
            return Result<Array<T>, CsvError>.err(value.error());
        }
        if (value.value().is_empty()) {
            return Result<Array<T>, CsvError>.ok(values);
        }
        values.append(value.value().value());
    }
    return Result<Array<T>, CsvError>.ok(values);
}

## Writes `values`, structs, as CSV: a header record of their property
## names, then one record per value, as `Writer.write` writes them.
##
## @typeParam T the struct to write
## @param values the values to write
## @param delimiter the one-byte text between fields
## @param line_ending the text after each record: `"\n"`, or `"\r\n"` as
##   RFC 4180 says
## @returns the CSV text; empty when `values` is
## @panics if `delimiter` is not one byte, or is `"`, `\r` or `\n`
## @example
##     import csv;
##
##     struct Point {
##         var x: int;
##         var label: String;
##     }
##
##     main(): int {
##         var p = Point();
##         p.x = 1;
##         p.label = "a, b";
##         assert(csv.encode([p]) == "x,label\n1,\"a, b\"\n", "a header and a record");
##         return 0;
##     }
export encode<T>(values: Array<T>, delimiter: String = ",", line_ending: String = "\n"): String {
    var out = io.ByteWriter();
    var writer = Writer(out, delimiter, line_ending);
    for (var value in values) {
        writer.write(value);
    }
    return text.Utf8.decode_lossy(out.bytes);
}

# Converts one record, whose fields `header` names, to a `T`.
_csv_from_row<T>(
    header: Array<String>, fields: Array<String>, unknown_keys: json.UnknownKeys
): Result<T, json.JsonError> {
    var text_keys = Array<String>();
    var string_keys = Array<String>();
    _csv_text_keys<T>(text_keys, string_keys);
    var object = json.JsonValue.object();
    for (var index in 0..header.count) {
        var key = header[index];
        var field = fields[index];
        if (field.is_empty && !string_keys.contains(key)) {
            continue;
        }
        if (text_keys.contains(key)) {
            object[key] = json.JsonValue.String(field);
            continue;
        }
        object[key] = _csv_scalar(field);
    }
    return json.from_json<T>(object, unknown_keys);
}

# Appends to `text_keys` the columns of `T`'s properties that hold text,
# which a field fills as it is, and to `string_keys` those of them that are
# `String`s, not `String?`s, which an empty field fills too.
_csv_text_keys<T>(text_keys: Array<String>, string_keys: Array<String>) {
    static (text_keys, string_keys) {
        reflect.assert(
            reflect.is_struct<T>(), $"'csv' converts records to and from structs, not '{reflect.name<T>()}'"
        );
        for (var field in reflect.properties<T>()) {
            if (field.has_attribute<serialize.Ignore>()) {
                continue;
            }
            if (reflect.is_same<field.Type, String>() || reflect.is_same<field.Type, String?>()) {
                var key = field.name;
                if (field.has_attribute<serialize.Name>()) {
                    key = field.attribute<serialize.Name>().value;
                }
                text_keys.append(key);
                if (reflect.is_same<field.Type, String>()) {
                    string_keys.append(key);
                }
            }
        }
    }
}

# A field as JSON reads it, when it is a number, a boolean or null, and
# otherwise as a string.
_csv_scalar(field: String): json.JsonValue {
    var parsed = json.parse(field);
    if (parsed.is_err()) {
        return json.JsonValue.String(field);
    }
    var value = parsed.value();
    if (value.is_null() || value.as_bool().is_value() || value.as_int().is_value() || value.as_double().is_value()) {
        return value;
    }
    return json.JsonValue.String(field);
}

# The column a conversion error is about (the first when it names none),
# and its message, which names the column rather than a JSON path.
_csv_place(header: Array<String>, error: json.JsonError): (ulong, String) {
    var message = error.message;
    var prefix = error.value_path + ": ";
    if (message.starts_with(prefix)) {
        message = message.substr_bytes(prefix.size, message.size - prefix.size);
    }
    for (var index in 0..header.count) {
        var key = header[index];
        if (error.value_path == $"$.{key}" || error.value_path == $"$[{json.JsonValue.String(key).to_string()}]") {
            return (index, $"column '{key}': {message}");
        }
    }
    return (0, message);
}

# The fields `to_json` makes of a struct, in the order of its properties.
_csv_fields<T>(value: T): OrderedMap<String, json.JsonValue> {
    _csv_text_keys<T>(Array<String>(), Array<String>());
    return json.to_json(value).as_object().value();
}

# A field as `Writer.write` writes it: a string as it is, `null` as an
# empty field, anything else as JSON text.
_csv_text_of(value: json.JsonValue): String {
    if (value is String(text)) {
        return text;
    }
    if (value.is_null()) {
        return "";
    }
    return value.to_string();
}
