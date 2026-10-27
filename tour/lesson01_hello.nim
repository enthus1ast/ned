# Nim tour · 1 of 16 · Hello, Nim
# notebook: compiled
#
# Welcome. This file is a notebook: Nim code cut into cells by the lines that start with `# %%`. Put the cursor in
# a cell and press Ctrl+Enter, or tap ▶ run on its `# %%` line. ned builds the cells from the top down to that one
# as one program, runs it, and shows under each cell what it printed. Shift+Enter runs the cell and moves to the
# next one.
#
# The line `# notebook: compiled` above makes the lessons real programs, so everything Nim can do works in them;
# a run takes a second or two.
#
# Lines that start with `#>` show what a cell should print. Each lesson ends with an exercise: change the code above
# its `# Check:` line until the check says ✓. An answer is folded away under `# Answer:` — put the cursor on that
# line and press Alt+= (or click the ▸ beside it) when you want to look.
#
# The lessons are your own copies: change anything and run it again. Help › Nim tour has the next and the previous
# lesson, all of them (a ✓ beside each one whose exercise you passed), and "reset this lesson" for a fresh copy.

# %% Say hello
# `echo` prints what it is given, then ends the line. A string is written between double quotes.
echo "Hello, Nim!"
#> Hello, Nim!

# %% Several things at once
# echo takes any number of arguments, separated by commas, and prints them one after the other. Arithmetic is
# worked out first: 6 * 7 prints 42.
echo "6 * 7 = ", 6 * 7
echo "one", "two", "three"
#> 6 * 7 = 42
#> onetwothree

# %% Names for values
# `let` gives a value a name. Each statement goes on a line of its own; a block (you will meet them in lesson 3)
# is indented by two spaces. Nim reads the indentation: there are no braces and no semicolons.
let name = "Ada"
let born = 1815
echo "Hello, ", name, " — born in ", born
#> Hello, Ada — born in 1815

# %% Joining strings
# `&` joins two strings into one; `$` turns a value (here a number) into a string.
let greeting = "Hello, " & name & "!"
echo greeting
echo "Born in " & $born
#> Hello, Ada!
#> Born in 1815

# %% Comments
# A `#` starts a comment, which runs to the end of the line. `#[` and `]#` hold a comment of several lines.
#[ The compiler skips
  all of this. ]#
echo "comments print nothing"  # nor does this one
#> comments print nothing

# %% When something is wrong
# The compiler reads the whole program before it runs any of it. A mistake stops it: it says what and where, in red
# under the cell, and ned marks the line. Try it: take away the closing quote of "world" and run the cell. Put the
# quote back and run it again.
echo "hello, ", "world"
#> hello, world

# %% Exercise: your own greeting
# Put your own name in `who`, and make `message` say "Hello, " then the name then "!" — joined with `&`, as above.
# Run the cell: the check says ✓ when it is right, or "not yet" and what it found. (The check uses `if`, which
# lesson 3 explains.)
let who = "World"
let message = ""
echo message
# Check:
if who == "World": echo "not yet: put your own name in `who`"
elif message != "Hello, " & who & "!": echo "not yet: message is \"", message, "\""
else: echo "✓ ", message
# Answer:
  # let who = "Grace"
  # let message = "Hello, " & who & "!"
  # echo message
