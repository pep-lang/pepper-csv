# The csv package's struct conversion: `decode` and `encode`, and
# `Reader.read` and `Writer.write`, through reflection, with the
# `serialize` attributes, and errors at the field they are about.

import csv;
import io;
import json;
import serialize;
import text;

enum Level {
    Low,
    High,
}

struct Account {
    [Required]
    var name: String;
    var balance: double;
    var visits: int;
    var active: bool;
    [Name("e-mail")]
    var email: String?;
    var level: Level;
    var limit: int?;
    var code: String;
    [Ignore]
    var cached: long;
}

[Test]
decodes_records() {
    var text = "name,balance,visits,active,e-mail,level,limit,code,extra\nada,12.5,3,true,ada@example.com,High,,007,x\nbob,-1,0,false,,Low,40,,\n";
    var accounts = csv.decode<Account>(text).value();
    expect_equal(accounts.count, 2);
    expect_equal(accounts[0].name, "ada");
    expect_equal(accounts[0].balance, 12.5);
    expect_equal(accounts[0].visits, 3);
    expect_true(accounts[0].active);
    expect_equal(accounts[0].email.value(), "ada@example.com");
    expect_true(accounts[0].level is High);
    expect_true(accounts[0].limit.is_empty());
    expect_equal(accounts[0].code, "007");
    expect_true(accounts[1].email.is_empty());
    expect_equal(accounts[1].limit.value(), 40);
    expect_equal(accounts[1].code, "");
}

[Test]
encodes_records() {
    var account = Account();
    account.name = "ada, the first";
    account.balance = 2.5;
    account.visits = 7;
    account.email = Optional<String>.Empty;
    account.level = Level.High;
    account.code = "42";
    account.cached = 9;
    expect_equal(
        csv.encode([account]),
        "name,balance,visits,active,e-mail,level,limit,code\n\"ada, the first\",2.5,7,false,,High,,42\n"
    );
    var back = csv.decode<Account>(csv.encode([account, account])).value();
    expect_equal(back.count, 2);
    expect_equal(back[1].name, "ada, the first");
    expect_equal(back[1].code, "42");
    expect_true(back[1].email.is_empty());
    expect_equal(csv.encode(Array<Account>()), "");
}

[Test]
reads_and_writes_a_stream() {
    var reader = csv.Reader(io.ByteReader("visits,name\n1,a\n2,b\n".bytes()));
    var first = reader.read<Account>().value().value();
    expect_equal(reader.header[1], "name");
    expect_equal(first.visits, 1);
    expect_equal(reader.read<Account>().value().value().name, "b");
    expect_true(reader.read<Account>().value().is_empty());

    var out = io.ByteWriter();
    var writer = csv.Writer(out, line_ending = "\r\n");
    expect_true(writer.write(first).is_ok());
    expect_true(writer.write(first).is_ok());
    expect_equal(
        text.Utf8.decode_lossy(out.bytes),
        "name,balance,visits,active,e-mail,level,limit,code\r\na,0.0,1,false,,Low,,\r\na,0.0,1,false,,Low,,\r\n"
    );
}

[Test]
locates_conversion_errors() {
    expect_equal(
        csv.decode<Account>("name,visits\nada,many\n", path = "a.csv").error().to_string(),
        "a.csv:2:5: error: column 'visits': expected a number, found a string"
    );
    expect_equal(
        csv.decode<Account>("name,visits\nada,1.5\n", path = "a.csv").error().to_string(),
        "a.csv:2:5: error: column 'visits': expected an integer, found 1.5"
    );
    expect_equal(
        csv.decode<Account>("visits\n1\n", path = "a.csv").error().to_string(),
        "a.csv:2:1: error: missing required key 'name'"
    );
    expect_equal(
        csv.decode<Account>("name,level\nada,Middle\n").error().to_string(),
        "2:5: error: column 'level': 'Middle' is not a case of 'Level'"
    );
    expect_equal(
        csv.decode<Account>("name,e-mail\nada,1\n,\"x\ny\",z\n").error().to_string(),
        "3:1: error: expected 2 fields, as the header has, but found 3"
    );
    expect_equal(csv.decode<Account>("name,visits,name\n").error().to_string(), "1:13: error: duplicate column 'name'");
    expect_equal(
        csv.decode<Account>("name,other\nada,1\n", unknown_keys = json.UnknownKeys.Reject).error().to_string(),
        "2:5: error: column 'other': unknown key 'other'"
    );
}
