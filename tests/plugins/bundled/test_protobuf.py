"""protobuf: the language (colours, comments, indentation, F5 with buf or protoc, the check: buf lint), its snippets,
the outline without a language server, protols (or bufls) and buf format when they are installed, the settings"""
import os, shutil, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language, done, fake_tools, ned_cmd, run_sh, start
from tplugins import check

SAMPLE = '''// a comment: message NotThis {}
syntax = "proto3";

package shop.v1;

import "google/protobuf/timestamp.proto";

/* message Nope {} */
message Order {
  string id = 1;
  repeated Item items = 2;
  map<string, int32> counts = 3;
  google.protobuf.Timestamp created = 4 [deprecated = true];
  string note = 7 [default = "message Fake {"];

  message Item {
    string sku = 1;
  }

  oneof payment {
    string card = 5;
    string cash = 6;
  }
  reserved 8, 9;
}

enum Status {
  option allow_alias = true;
  STATUS_UNSPECIFIED = 0;
  STATUS_DONE = 1;
}

service Shop {
  rpc GetOrder(GetOrderRequest) returns (Order);
  rpc Watch(stream WatchRequest) returns (stream Order) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
}'''.split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "protobuf",
        {"name": "Protobuf", "extensions": ["proto"], "lineComment": "//", "blockComment": ["/*", "*/"],
         "quotes": "\"'", "capitalTypes": True, "indentSize": 2, "dedent": "})]", "build": "buf build",
         "check": "buf lint \"$file\"",
         "keywords": {"syntax", "package", "import", "message", "enum", "service", "rpc", "returns", "stream",
                      "oneof", "map", "repeated", "optional", "reserved", "option", "edition"},
         "types": {"int32", "int64", "string", "bytes", "bool", "double", "fixed64"},
         "constants": {"true", "false"}},
        ["syntax", "message", "enum", "service", "rpc", "oneof"],
        SAMPLE,
        [("shop.v1", "module", 0), ("Order", "struct", 0), ("id", "field", 1), ("items", "field", 1),
         ("counts", "field", 1), ("created", "field", 1), ("note", "field", 1), ("Item", "struct", 1),
         ("sku", "field", 2), ("payment", "struct", 1), ("card", "field", 2), ("cash", "field", 2),
         ("Status", "enum", 0), ("STATUS_UNSPECIFIED", "constant", 1), ("STATUS_DONE", "constant", 1),
         ("Shop", "interface", 0), ("GetOrder", "method", 1), ("Watch", "method", 1)],
        ["buf", "protoc", "protols", "bufls"],
        runs=[("shop.proto", "syntax = \"proto3\";\n", {}, "buf build $file"),
              ("proto/shop/v1/shop.proto", "syntax = \"proto3\";\n", {"buf.gen.yaml": "version: v2\n"},
               "buf generate")],
        server=["protols"], formatter="buf format --stdin-filepath \"$file\"")

    # bufls when protols is not installed; F5 with protoc when buf is not
    tmp = tempfile.mkdtemp(prefix="ned-protobuf-")
    try:
        fake = os.path.join(tmp, "bin")
        fake_tools(fake, ["bufls", "protoc"])
        h, ok, err = start(factory, [fake], only_path=True)
        ls = h.reg("lsp", lang="protobuf") if ok else None
        run_cmd = (h.reg("language", id="protobuf") or {}).get("spec", {}).get("run", "") if ok else ""
        check(tag + "bufls installed (no protols): bufls serve; no buf: no formatter",
              ok and ls and ls["cmd"] == ["bufls", "serve"] and h.reg("formatter", lang="protobuf") is None,
              (err, ls))
        done(h)
        f = os.path.join(tmp, "loose", "shop.proto")
        os.makedirs(os.path.dirname(f))
        open(f, "w").write("syntax = \"proto3\";\n")
        o = run_sh(ned_cmd(run_cmd, f, "/T"), os.path.dirname(f), [fake])
        check(tag + "F5 without buf: protoc, the file compiled in its folder",
              o.startswith("protoc -I . -o /dev/null shop.proto\nin %s\n" % os.path.dirname(f)), o)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
