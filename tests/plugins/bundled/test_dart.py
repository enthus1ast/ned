"""dart — the language (colours, comments, indentation, F5: dart run, dart test or flutter run), its snippets, the
outline, Dart's language server and dart format when dart is installed, the settings"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language

SAMPLE = """// a comment: void nope() {}
import 'dart:math';

/* a block: class Nope {} */
const limit = 10;
final greeting = 'void fake() {';

typedef Callback = void Function(int);

abstract class Shape {
  double get area;
  String describe() => 'shape';
}

class Square extends Shape {
  Square(this.side);
  Square.unit() : side = 1;
  final double side;

  @override
  double get area => side * side;

  static Square twice(Square s) {
    if (s.side > 0) {
      return Square(s.side * 2);
    }
    return s;
  }
}

mixin Loud {
  void shout() {}
}

enum Color { red, green }

extension Doubled on int {
  int get doubled => this * 2;
}

Future<void> load() async {
  final text = '''
  void notAFunction() {
  ''';
  print(text);
}

T first<T>(List<T> xs) => xs[0];

void main() {
  print(Square(2).area);
}""".split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "dart",
        {"name": "Dart", "extensions": ["dart"], "lineComment": "//", "docComment": "///",
         "blockComment": ["/*", "*/"], "quotes": "\"'", "tripleQuotes": True, "capitalTypes": True,
         "decorators": True, "indentSize": 2, "dedent": "})]",
         "keywords": {"class", "final", "const", "var", "late", "async", "await", "extends", "mixin", "enum",
                      "required", "import", "return"},
         "types": {"int", "double", "String", "List", "Future", "void"}, "constants": {"true", "false", "null"},
         "build": "dart compile exe \"$file\"", "check": "dart analyze \"$file\""},
        ["main", "class", "stless", "stful", "test", "async", "for", "switch"],
        SAMPLE,
        [("limit", "constant", 0), ("greeting", "variable", 0), ("Callback", "type", 0), ("Shape", "class", 0),
         ("area", "property", 1), ("describe", "method", 1), ("Square", "class", 0), ("Square", "constructor", 1),
         ("Square.unit", "constructor", 1), ("side", "field", 1), ("area", "property", 1), ("twice", "method", 1),
         ("Loud", "interface", 0), ("shout", "method", 1), ("Color", "enum", 0), ("Doubled", "class", 0),
         ("doubled", "property", 1), ("load", "function", 0), ("first", "function", 0), ("main", "function", 0)],
        ["dart", "flutter"],
        runs=[("hello.dart", "void main() {}\n", {}, "dart run $file"),
              ("test/app_test.dart", "void main() {}\n", {"pubspec.yaml": "name: app\n"}, "dart test $file"),
              ("bin/app.dart", "void main() {}\n", {"pubspec.yaml": "name: app\n"}, "dart run $file"),
              ("lib/main.dart", "void main() {}\n",
               {"pubspec.yaml": "name: app\ndependencies:\n  flutter:\n    sdk: flutter\n"}, "flutter run")],
        server=["dart", "language-server", "--protocol=lsp"], formatter="dart format")
