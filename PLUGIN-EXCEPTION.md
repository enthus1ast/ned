# The ned Plugin Exception

An additional permission under section 7 of the GNU General Public License, version 3.

ned is free software under the GNU General Public License, version 3 or (at your option) any later version (see
[LICENSE](LICENSE)). The two files of its plugin library — `src/ned/plugins/lib/nedplugin.nim` and
`src/ned/plugins/lib/nedlsp.nim` — are covered by that licence together with the following additional permission.

1. **A plugin**, here, is a work that ned's plugin host runs — a `plugin.nims` run with `nim e`, a `plugin.nim`
   compiled into a program of its own, or a language server in NimScript run with `ned --lsp-bridge` — that works
   with ned only through the plugin library and the messages it exchanges with ned, and that contains no other part
   of ned.

2. **The permission.** You may combine a plugin with the plugin library — import it, compile the two together — and
   convey the plugin, with or without the plugin library, under terms of your choice. The plugin library itself
   stays under the GNU General Public License with this exception, and so does any part of it you convey.

3. **What it does not cover.** This permission is only for plugins as defined above. ned itself — its other source
   files, and changes to them — and any work that contains other parts of ned remain under the GNU General Public
   License without this exception.

If you modify the plugin library, you may extend this exception to your version of it, but you are not obliged to.
If you do not wish to, delete this exception statement from your version.
