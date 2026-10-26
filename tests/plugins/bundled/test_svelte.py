"""svelte: the language (colours, comments, indentation, F5 with the project's package manager), its snippets, the
outline without svelteserver (scripts, props, state, functions, snippets, style), svelteserver and prettier when
they are installed, the settings"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language, done, start
from tplugins import check

SAMPLE = '''<script module>
  export const VERSION = "1.0";
</script>

<script lang="ts">
  import Button from './Button.svelte';
  // const notThis = 1;
  let {
    title,
    count = 0
  } = $props();
  let items = $state([]);
  const doubled = $derived(count * 2);
  const label = `function fake() {
    still the template`;
  const format = (n: number) => n.toFixed(2);

  function add(item: string) {
    const inner = item;   // a local: not in the outline
    items.push(inner);
  }
</script>

<!-- {#snippet notThis()} -->
{#snippet row(item)}
  <li>{item}</li>
{/snippet}

<h1>{title}</h1>
<Button onclick={() => add('x')}>Add</Button>

<style>
  h1 { color: red; }
</style>'''.split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "svelte",
        {"name": "Svelte", "extensions": ["svelte"], "blockComment": ["<!--", "-->"],
         "docBlockComment": ["/*", "*/"], "quotes": "\"'`", "capitalTypes": True, "decorators": True,
         "indentSize": 2, "dedent": "})]",
         "keywords": {"const", "let", "function", "import", "export", "if", "else", "each", "as", "await", "then",
                      "snippet"},
         "constants": {"true", "false", "null", "undefined"}},
        ["script", "style", "if", "each", "await", "snippet", "props", "state", "derived", "effect"],
        SAMPLE,
        [("script", "section", 0), ("VERSION", "constant", 1), ("script", "section", 0), ("title", "property", 1),
         ("count", "property", 1), ("items", "variable", 1), ("doubled", "constant", 1), ("label", "constant", 1),
         ("format", "function", 1), ("add", "function", 1), ("row", "function", 0), ("style", "section", 0)],
        ["npm", "pnpm", "svelteserver", "prettier"],
        runs=[("src/routes/+page.svelte", "<h1>hi</h1>\n", {"package.json": "{}\n"}, "npm run dev"),
              ("src/App.svelte", "<h1>hi</h1>\n", {"package.json": "{}\n", "pnpm-lock.yaml": "\n"}, "pnpm run dev")],
        server=["svelteserver", "--stdio"], formatter="prettier --stdin-filepath \"$file\"")

    # the props on one line; Svelte 4's `export let`
    h, ok, err = start(factory)
    r = h.reg("symbols", lang="svelte") if ok else None
    got = []
    if r:
        h.lines = ["<script>", "  let { a, b = 1, c: d, ...rest } = $props();", "  export let old = 2;", "</script>"]
        got = [(s["name"], s["kind"], s["detail"]) for s in (h.call(r["cb"], {"buf": 1}) or {}).get("value") or []]
    check(tag + "the props of one line (renamed and the rest too) and Svelte 4's export let",
          got == [("script", "section", ""), ("a", "property", "prop"), ("b", "property", "prop"),
                  ("c", "property", "prop"), ("rest", "property", "prop"), ("old", "property", "prop")], got)
    done(h)
