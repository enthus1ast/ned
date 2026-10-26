"""swift: the language (colours, comments, indentation, F5), its snippets, the outline without sourcekit-lsp,
sourcekit-lsp and swift-format when they are installed (pretend ones here), the plugin's two settings"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language

SAMPLE = '''import Foundation

/// A shape: func notThis() {}
protocol Shape {
    func area() -> Double
}

/* a block comment /* nested: func nope() */ still */
struct Square: Shape {
    let side: Double
    var label = "func fake() {"

    init(side: Double) {
        self.side = side
    }

    func area() -> Double {
        let inner = side * side      // a local: not in the outline
        return inner
    }
}

enum Direction {
    case north, south
    func turned() -> Direction { self }
}

extension Square {
    static func unit() -> Square { Square(side: 1) }
}

final class Counter {
    private(set) var count = 0
    class func make() -> Counter { Counter() }
}

typealias Area = Double
let limit = 10
var names: [String] = []

@MainActor
func main() async {
    let text = """
    func notThis() {}
    """
    print(text)
}'''.split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "swift",
        {"name": "Swift", "extensions": ["swift"], "lineComment": "//", "blockComment": ["/*", "*/"],
         "nestedComments": True, "docComment": "///", "quotes": "\"", "tripleQuotes": True, "capitalTypes": True,
         "decorators": True, "indentSize": 2, "dedent": "})]",
         "keywords": {"func", "let", "var", "struct", "class", "enum", "protocol", "extension", "guard", "init",
                      "async", "await", "throws", "some", "actor"},
         "constants": {"true", "false", "nil"}, "build": "swift build", "check": "swiftc -parse \"$file\""},
        ["func", "struct", "class", "enum", "protocol", "extension", "guard", "iflet", "for", "switch", "test"],
        SAMPLE,
        [("Shape", "interface", 0), ("area", "method", 1), ("Square", "struct", 0), ("side", "property", 1),
         ("label", "property", 1), ("init", "method", 1), ("area", "method", 1), ("Direction", "enum", 0),
         ("turned", "method", 1), ("Square", "class", 0), ("unit", "method", 1), ("Counter", "class", 0),
         ("count", "property", 1), ("make", "method", 1), ("Area", "type", 0), ("limit", "constant", 0),
         ("names", "variable", 0), ("main", "function", 0)],
        ["swift", "swiftc", "sourcekit-lsp", "swift-format"],
        runs=[("hello.swift", "print(1)\n", {}, "swift $file"),
              ("Sources/App/main.swift", "print(1)\n", {"Package.swift": "// swift-tools-version:5.9\n"},
               "swift run"),
              ("Tests/AppTests/AppTests.swift", "import Testing\n", {"Package.swift": "// swift-tools-version:5.9\n"},
               "swift test")],
        server=["sourcekit-lsp"], formatter="swift-format format --assume-filename \"$file\"")
