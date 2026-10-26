"""graphql: the language (colours, comments, indentation), its snippets, the outline without a language server
(schemas and operations), graphql-lsp and prettier when they are installed (pretend ones here), the settings"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language

SAMPLE = '''# A comment: type NotThis { x: Int }
schema {
  query: Query
}

"""
A user: type NotThat { y: Int }
"""
type User implements Node @key(fields: "id") {
  id: ID!
  "the name: fake: Int"
  name: String
  posts(
    first: Int = 10
  ): [Post!]!
}

extend type User {
  age: Int @deprecated(reason: "use birthday")
}

enum Role {
  ADMIN
  USER @deprecated(reason: "use MEMBER")
}

input NewUser {
  name: String!
}

scalar Date
union SearchResult = User | Post
directive @auth(requires: Role = ADMIN) on FIELD_DEFINITION

query GetUser($id: ID!) {
  user(id: $id) {
    ...UserFields
  }
}

fragment UserFields on User {
  name
}'''.split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "graphql",
        {"name": "GraphQL", "extensions": ["graphql", "gql", "graphqls"], "lineComment": "#", "quotes": "\"",
         "tripleQuotes": True, "capitalTypes": True, "decorators": True, "indentSize": 2, "dedent": "})]",
         "keywords": {"query", "mutation", "subscription", "fragment", "on", "type", "interface", "union", "enum",
                      "input", "scalar", "schema", "extend", "implements", "directive"},
         "types": {"Int", "Float", "String", "Boolean", "ID"}, "constants": {"true", "false", "null"}},
        ["query", "mutation", "fragment", "type", "input", "enum", "interface"],
        SAMPLE,
        [("schema", "module", 0), ("query", "field", 1), ("User", "class", 0), ("id", "field", 1),
         ("name", "field", 1), ("posts", "field", 1), ("User", "class", 0), ("age", "field", 1), ("Role", "enum", 0),
         ("ADMIN", "constant", 1), ("USER", "constant", 1), ("NewUser", "struct", 0), ("name", "field", 1),
         ("Date", "type", 0), ("SearchResult", "type", 0), ("@auth", "function", 0), ("GetUser", "function", 0),
         ("UserFields", "function", 0)],
        ["graphql-lsp", "prettier"],
        runs=(),
        server=["graphql-lsp", "server", "-m", "stream"], formatter="prettier --stdin-filepath \"$file\"")
