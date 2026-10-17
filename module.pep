## CSV (RFC 4180): read records from a stream or a text, write them back,
## and convert structs to records and back.
##
## Bring it in with `import csv`. Reading is strict and safe for untrusted
## text: a malformed record is an error with its line and column, like a
## compiler's, and a record may not pass a set size, so a quote that never
## closes cannot fill memory. A `Reader` reads a record at a time, so a
## large file is never held whole.
##
## - `Reader`, `parse`, `CsvError`: reading
## - `Writer`, `write_all`: writing
## - `decode`, `encode`, `Reader.read`, `Writer.write`: struct conversion,
##   with the attributes of the `serialize` module, as `json` converts
##   structs
##
## @example
##     import csv;
##
##     main(): int {
##         var parsed = csv.parse("name,tags\nada,\"cli, csv\"\n", path = "people.csv");
##         if (parsed.is_err()) {
##             print(parsed.error().to_string());
##             return 1;
##         }
##         var rows = parsed.value();
##         assert(rows[1][1] == "cli, csv", "a quoted field");
##         rows[1][0] = "bob";
##         print(csv.write_all(rows));
##         return 0;
##     }

# This file only gathers the module's public API from its other files.

import "convert";
import "read";
import "write";

export CsvError;
export Reader;
export parse;
export Writer;
export write_all;
export decode;
export encode;
