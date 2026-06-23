# Building `janetd`: a hands-on tour of Janet

This is a build-it-yourself tutorial. By the end you'll have written a
small but genuinely useful long-running daemon — a "systemd-lite" that
schedules, queues, triggers, retries, logs, and alerts on shell jobs —
and along the way you'll have met most of the Janet language: its data
structures, functions, macros, the fiber/event-loop concurrency model,
processes, sockets, and the module system.

The pace is deliberately slow. Each part introduces only a few new
ideas, gives you a small file you can run on its own, and tells you
exactly what to type to see it work. You are encouraged to actually run
every snippet. Nothing here is magic; the whole finished program is
under 900 lines.

## How to use this tutorial

- **Type the code, don't paste it.** Muscle memory and small typos are
  where most of the learning happens.
- **Run the checkpoints.** Each part ends with commands you can run and
  the output you should see. If your output differs, that's a clue
  worth chasing before moving on.
- **Read the "Why" asides.** They explain a Janet idiom or a design
  decision rather than just restating the code.

When you finish you'll have this layout:

```
janetd/
  janetd            # CLI entry point
  src/
    util.janet       # helpers: paths, time, persistence, logging
    schedule.janet   # "when does this job run next?"
    runner.janet     # run one job attempt, capture output, enforce timeout
    alerts.janet     # detect failures, send alerts
    daemon.janet     # the engine: scheduler + queue + retries + control socket
    client.janet     # talk to a running daemon
  examples/jobs.janet
```

We build them bottom-up: the leaf utilities first, then the pieces that
use them, then the engine that ties everything together, then the CLI.

---

## Part 0 — Getting Janet and saying hello

### Install Janet

Janet is a single small C program with no runtime dependencies. The
[official install page](https://janet-lang.org/docs/index.html) covers
package managers, but building from source takes under a minute and is
the most reliable option:

```sh
git clone https://github.com/janet-lang/janet.git
cd janet
make
sudo make install      # installs to /usr/local by default
janet --version        # should print something like 1.38.0-...
```

Everything in this tutorial was written and tested against Janet
**1.38.0**. If you're on a meaningfully older version some functions may
behave differently; upgrade if you hit surprises.

Janet ships two things we'll use:

- `janet` — the interpreter. Run a file with `janet file.janet`, or
  evaluate a one-liner with `janet -e '(print "hi")'`, or start an
  interactive REPL with just `janet`.
- The standard library, which is large and batteries-included:
  filesystem, time, subprocess, networking, an event loop, PEG parsing,
  and more, all built in. We won't install a single external package.

### A 90-second taste of the syntax

Janet is a Lisp. Code is written as **s-expressions**: parentheses where
the first element is the thing being called and the rest are arguments.

```janet
(print "hello")          # calls print with one argument
(+ 1 2 3)                # => 6   ; + is just a function
(* (+ 1 2) 4)            # => 12  ; nesting works how you'd expect
```

Open a REPL and try them (`janet`, then Ctrl-D to exit):

```janet
$ janet
repl:1:> (+ 1 2 3)
6
repl:2:> (string "a" "b" "c")
"abc"
repl:3:> (print "hi")
hi
nil
```

That last one is worth a pause: `print` returns `nil` after printing, and
the REPL shows you both the side effect (`hi`) and the return value
(`nil`). In Janet, **everything is an expression** that evaluates to a
value.

A few core data types you'll use constantly:

```janet
42 3.14                  # numbers (all numbers are 64-bit doubles)
"a string"               # strings
:keyword                 # keywords — interned labels, like symbols you compare by identity
'symbol                  # a quoted symbol
true false nil           # booleans and the absence of a value
[1 2 3]                  # a tuple   (immutable, like a fixed list)
@[1 2 3]                 # an array  (mutable)
{:a 1 :b 2}              # a struct  (immutable key/value)
@{:a 1 :b 2}             # a table   (mutable key/value)
```

> **Why the `@`?** Janet draws a hard line between immutable literals
> (`[...]`, `{...}`) and mutable containers (`@[...]`, `@{...}`). The `@`
> reads as "mutable". We'll lean on this distinction later — for example,
> a bug we'll deliberately walk into is trying to mutate a struct that
> should have been a table.

Indexing uses the collection as a function, or `get`:

```janet
(def xs [10 20 30])
(xs 1)                   # => 20
(get xs 5)               # => nil  (out of range is nil, not an error)
(def m {:name "ada"})
(m :name)                # => "ada"
(get m :missing :default)# => :default
```

Comments start with `#`. Docstrings (which we'll write a lot of) are
delimited with backticks and come right after a function's name.

That's enough to start. We'll introduce the rest — `def`, `defn`, `var`,
`fn`, control flow, destructuring, `string/format`, and so on — exactly
when we first need them, so they stick.

### Set up your project

```sh
mkdir -p janetd/src janetd/examples
cd janetd
```

Now create one throwaway file to confirm your toolchain works.

`hello.janet`:

```janet
(print "janetd tutorial: toolchain works")
```

Checkpoint:

```sh
$ janet hello.janet
janetd tutorial: toolchain works
```

If you see that line, you're ready. Delete `hello.janet` and let's build
the real thing.

---

## Part 1 — `util.janet`: functions, control flow, and the standard library

Our first real file holds the small helpers everything else leans on:
making directories, formatting timestamps, saving and loading data, and
the daemon's own logger. It's the perfect place to learn Janet's core
building blocks because each helper is tiny.

We'll write it function by function. Create `src/util.janet` and add a
header comment:

```janet
### util.janet
### Shared helpers used across janetd: filesystem, timestamps,
### simple persistence, and the daemon's own structured log writer.
```

### Defining functions: `defn`, parameters, docstrings

Add this:

```janet
(defn now-unix [] (os/time))
```

`defn` defines a named function. The shape is `(defn name [params] body...)`.
Here `now-unix` takes no parameters (`[]`) and its body is a single call
to `os/time`, which returns the current Unix timestamp (seconds since
1970) as a number. The last expression in a function body is its return
value — there is no `return` keyword.

> **Why wrap `os/time` at all?** It's a one-line indirection that gives
> us a single obvious place to look when we talk about "the current
> time", and would let us swap in a fake clock for testing later. Small
> seams like this are cheap and pay off.

Try it in the REPL from inside your project directory:

```janet
$ janet -e '(import ./src/utils :as u) (print (u/now-unix))'
1781990000
```

We just met `import`: it loads another file as a module. `./src/util`
is a path relative to the current directory (the leading `./` matters —
it tells Janet this is a file path, not an installed library). `:as u`
gives the module a short local prefix, so `now-unix` becomes `u/now-unix`.

### `string/format`, `os/date`, and keyword indexing

Daemons live and die by their logs, and logs need readable timestamps.
Add:

```janet
(defn iso-timestamp
  ``Render a unix timestamp (default: now) as a sortable, human
  readable local timestamp string, e.g. 2026-06-20T14:03:05``
  [&opt t]
  (def d (os/date (or t (now-unix)) true))
  (string/format "%04d-%02d-%02dT%02d:%02d:%02d"
                  (d :year) (inc (d :month)) (inc (d :month-day))
                  (d :hours) (d :minutes) (d :seconds)))
```

There's a lot of Janet packed into six lines. Let's unpack it.

**The docstring.** Those backtick-delimited lines right after the name
are a docstring. Janet stores it; `(doc iso-timestamp)` in a REPL prints
it. Backticks (rather than `"..."`) let us write multi-line text without
escaping.

**`&opt`.** In the parameter list `[&opt t]`, the `&opt` marker means
every parameter after it is optional. If the caller doesn't supply `t`,
it's bound to `nil`. So `(iso-timestamp)` and `(iso-timestamp 1781990000)`
are both valid.

**`def` and `or` for defaults.** `(def d ...)` introduces a local
binding `d` that's visible for the rest of the function. The value is
`(os/date (or t (now-unix)) true)`. The idiom `(or t (now-unix))` is
Janet's standard "use the argument if given, otherwise a default":
`or` returns its first truthy argument, and since an omitted `t` is
`nil` (falsy), it falls through to `(now-unix)`.

**`os/date`.** This converts a Unix timestamp into a struct of calendar
fields. The second argument `true` asks for local time (omit it or pass
`false`/`nil` for UTC). The result looks like:

```janet
{:year 2026 :month 5 :month-day 19 :hours 14 :minutes 3 :seconds 5
 :week-day 4 :year-day 170 :dst false}
```

**Indexing a struct like a function.** `(d :year)` pulls the `:year`
field out of the struct `d`. This is the same "collection as function"
trick from Part 0.

**A subtle but important detail: zero-based fields.** Notice we write
`(inc (d :month))` and `(inc (d :month-day))` but not `(inc (d :year))`.
That's because `os/date` returns `:month` as **0–11** and `:month-day`
as **0–30** (zero-based), while `:year`, `:hours`, `:minutes`, and
`:seconds` are the natural numbers you'd expect. `inc` adds one. If you
forget this, every date you print is off by a month and a day — exactly
the kind of bug that's invisible until it isn't.

**`string/format`.** Works like `printf` in C. `%04d` means "an integer,
at least 4 wide, zero-padded". So we get `2026-06-20T14:03:05` with
consistent widths.

Let's prove the off-by-one handling is right. Run:

```janet
$ janet -e '(import ./src/util :as u) (print (u/iso-timestamp 1750000000))'
```

You should get a timestamp in your local timezone for that instant
(mid-June 2025). Cross-check it against the `date` command:

```sh
$ date -d @1750000000 +"%Y-%m-%dT%H:%M:%S"
```

The two should match. If your `iso-timestamp` is a month or a day off,
you dropped one of the `inc`s.

We need a second variant for filenames (colons are legal on Linux but
awful in paths and illegal on some filesystems):

```janet
(defn filename-timestamp
  ``Like iso-timestamp but safe to use inside a filename (no colons).``
  [&opt t]
  (def d (os/date (or t (now-unix)) true))
  (string/format "%04d%02d%02d-%02d%02d%02d"
                  (d :year) (inc (d :month)) (inc (d :month-day))
                  (d :hours) (d :minutes) (d :seconds)))
```

Same idea, different format string: `20260620-140305`.

### Strings, `var`, `cond`, and a bug worth meeting on purpose

Now the path helpers. A daemon writes files into nested directories that
might not exist yet, so we need a recursive `mkdir -p`. Janet's
`os/mkdir` only creates one level and errors if the directory exists, so
we build the path up component by component.

This function is also our first encounter with `var` (a *reassignable*
binding, versus `def` which is fixed), with `each` (iteration), and with
`cond` (multi-branch conditional). Add it:

```janet
(defn ensure-dir
  ``Recursively create a directory and all of its parents, ignoring
  the case where a component already exists.``
  [path]
  (var built "")
  (each part (string/split "/" path)
    (cond
      (empty? part) (when (empty? built) (set built "/"))
      (empty? built) (set built part)
      (= built "/") (set built (string built part))
      (set built (string built "/" part)))
    (unless (empty? built)
      (try (os/mkdir built) ([_] nil))))
  path)
```

Walk through it:

- `(var built "")` creates a mutable local starting as the empty string.
  Where `def` bindings can't be reassigned, `var` ones can — with `set`.
- `(string/split "/" path)` splits `"/tmp/janetd/logs"` into
  `@["" "tmp" "janetd" "logs"]`. Note the **leading empty string**: an
  absolute path starts with `/`, so the part before the first slash is
  `""`. This is the heart of the bug we're about to discuss.
- `each` iterates: `(each part collection body...)` runs the body once
  per element with `part` bound to each value.
- `cond` is a series of test/result pairs, tried top to bottom. The
  first truthy test wins. A lone trailing expression with no test (our
  last line) is the `else`. So we're rebuilding the cumulative path:
  start at `/` for an absolute path, then append `part` with the right
  separator each step.
- `(try (os/mkdir built) ([_] nil))` attempts the mkdir and **swallows
  any error**. `try`'s shape is `(try body ([err] handler))`; the `[_]`
  binds the error to `_` (the conventional "I'm ignoring this" name).
  We ignore it because "directory already exists" is fine for our
  purposes.
- The function returns `path` at the end, so callers can use it inline.

> **The bug we're meeting on purpose.** An earlier, simpler version of
> this function looked like:
>
> ```janet
> (var built "")
> (each part (string/split "/" path)
>   (set built (if (empty? built) part (string built "/" part)))
>   (unless (empty? built) (try (os/mkdir built) ([_] nil))))
> ```
>
> Trace it on `"/tmp/janetd"`. The split is `@["" "tmp" "janetd"]`.
> First iteration: `part` is `""`, `built` is `""`, so it stays `""` and
> we skip the mkdir. Second: `part` is `"tmp"`, `built` is empty, so
> `built` becomes `"tmp"` — **not** `"/tmp"`! We've silently dropped the
> leading slash and are now creating *relative* directories named
> `tmp/janetd` under wherever the process happens to be. On a daemon
> that's both wrong and a security smell.
>
> The fixed version uses `cond` to special-case the leading empty
> component into `built = "/"`, so absolute paths stay absolute. The
> lesson is broader than this one function: **`string/split` on a path
> hands you that leading empty string, and you have to decide what it
> means.** We hit this exact bug while building the real janetd and only
> caught it because a socket failed to bind in a directory that "should"
> have existed.

Two small companions, now that you can read them at a glance:

```janet
(defn dirname
  ``Return the directory portion of a path (everything before the
  final "/"). Returns "" if there is no "/" in path.``
  [path]
  (def parts (string/split "/" path))
  (string/join (slice parts 0 (max 0 (- (length parts) 1))) "/"))

(defn join-path
  ``Join path components with "/", ignoring empty pieces.``
  [& parts]
  (string/join (filter (fn [p] (not (empty? p))) parts) "/"))
```

`dirname` slices off the last component. `(slice parts 0 n)` returns
elements `0` up to (not including) `n`; `(- (length parts) 1)` is "all
but the last", and `max 0` guards against a negative when `parts` is
short. `string/join` is the inverse of `string/split`.

`join-path` shows two new things. First, `[& parts]` is a **variadic**
parameter list: `&` gathers all remaining arguments into an array
`parts`, so you can call `(join-path "a" "b" "c")`. Second,
`(fn [p] (not (empty? p)))` is an **anonymous function** — `fn` is like
`defn` without a name. `filter` keeps only elements for which that
function returns truthy, dropping empty strings so we don't get doubled
slashes.

Checkpoint — exercise all three:

```janet
$ janet -e '(import ./src/util :as u) \
  (u/ensure-dir "/tmp/janetd-tut/a/b/c") \
  (print "made: " (os/stat "/tmp/janetd-tut/a/b/c" :mode)) \
  (print "dirname: " (u/dirname "/tmp/janetd-tut/a/b/c/file.log")) \
  (print "join: " (u/join-path "/tmp" "" "x" "y"))'
made: directory
dirname: /tmp/janetd-tut/a/b/c
join: /tmp/x/y
```

`(os/stat path :mode)` asks the filesystem for just the `:mode` field of
a path's metadata; `directory` confirms our recursive mkdir reached the
deepest level *as an absolute path*.

### Persistence: `spit`, `slurp`, `%q`, and `parse`

The daemon needs to remember things across restarts — chiefly, when each
job last ran. We don't want a database for an MVP; we want the simplest
durable store that works. Janet gives us a lovely one almost for free,
because Janet data structures have a printed form that is also valid
Janet source. That format is called **JDN** (Janet Data Notation), the
Lisp world's equivalent of JSON.

```janet
(defn write-jdn
  ``Persist a Janet data structure to disk in a re-readable form.``
  [path data]
  (ensure-dir (dirname path))
  (def tmp (string path ".tmp"))
  (spit tmp (string/format "%q" data))
  (os/rename tmp path))

(defn read-jdn
  ``Read back data written by write-jdn. Returns dflt if the file is
  missing or unreadable/corrupt.``
  [path &opt dflt]
  (if (os/stat path)
    (try
      (parse (slurp path))
      ([_] dflt))
    dflt))
```

New pieces:

- `spit` writes a string to a file (creating/overwriting it). `slurp`
  reads a whole file back as a string. Memorable names.
- `(string/format "%q" data)` renders `data` as JDN. The `%q` verb means
  "quoted / re-readable representation". So `@{:a 1 :b [1 2 3]}` becomes
  the literal text `@{:a 1 :b (1 2 3)}`.
- `parse` reads a string of Janet source and returns the first datum —
  the inverse of `%q`. Round-trip: `(parse (string/format "%q" x))`
  gives you back a value equal to `x`.
- **The write-to-temp-then-rename dance.** We `spit` into `path.tmp`,
  then `os/rename` it over the real path. `os/rename` is atomic on a
  POSIX filesystem, so a reader (or a crash) never sees a half-written
  state file — it sees either the old complete file or the new complete
  file. This is the standard trick for crash-safe config/state writes,
  and it's worth internalizing.
- `read-jdn` guards twice: `os/stat` returns `nil` for a missing file
  (so we return the default), and `try` catches a corrupt file (so a
  garbled state file degrades to "start fresh" rather than crashing the
  daemon on boot).

> **A mutability gotcha you will hit.** When you `parse` a JDN string
> like `@{...}`, you get back a **table** (mutable) because the `@`
> survived the round-trip. But if you wrote a *struct* `{...}` (no `@`),
> you get back an immutable struct. Later, when we keep run-state in a
> table we mutate in place, we must make sure our *default* value (used
> when the file doesn't exist yet) is also a mutable `@{}` and not a
> plain `{}`. Pass `{}` and the first attempt to `put` into it throws
> "expected table, got struct". We hit precisely this and the fix was a
> single `@`. Keep the mutable/immutable distinction live in your head.

Checkpoint — round-trip a value through disk:

```janet
$ janet -e '(import ./src/util :as u) \
  (u/write-jdn "/tmp/janetd-tut/state.jdn" @{:count 3 :tags ["a" "b"]}) \
  (def back (u/read-jdn "/tmp/janetd-tut/state.jdn" @{})) \
  (print "read back: " (string/format "%q" back)) \
  (print "missing -> default: " (u/read-jdn "/tmp/nope.jdn" :default))'
read back: @{:count 3 :tags ("a" "b")}
missing -> default: default
```

(That last line prints `default`, not `:default`, because `print`
renders a keyword without its leading colon. The returned value really
is the keyword `:default` — use `pp` or `%q` instead of `print` if you
want to *see* the colon.)

(Notice the array `["a" "b"]` came back printed as a tuple `("a" "b")` —
`%q` renders immutable tuples without the `@`. The *values* are equal;
only the literal syntax differs.)

### Appending lines, and a module-level `var`

One more file helper — appending a single line, used by both the logger
and the alert log:

```janet
(defn append-line
  ``Append a single line to a file, creating its directory and itself
  if necessary.``
  [path line]
  (ensure-dir (dirname path))
  (def f (file/open path :a))
  (when f
    (file/write f line)
    (file/write f "\n")
    (file/close f)))
```

`file/open` with mode `:a` opens for appending (creating the file if
needed) and returns a file handle, or `nil` on failure. `when` is "`if`
with no else and an implicit body of several expressions": `(when test
body...)` runs the body only if `test` is truthy. We write the line, a
newline, and close.

### The logger: closures over module state, and splat

A daemon needs structured, timestamped, levelled log lines, written to a
file and optionally echoed to the terminal. We'll keep the destination
in a couple of **module-level vars** and expose an `init` plus the
logging functions.

```janet
(var- log-path nil)
(var- log-echo true)

(defn log-init
  ``Configure where daemon log lines are written, and whether they are
  also echoed to stdout (useful when running in the foreground).``
  [path &opt echo?]
  (set log-path path)
  (set log-echo (not= echo? false))
  (ensure-dir (dirname path)))
```

`var-` (with the trailing dash) is a **private** module-level var:
private bindings aren't exported when another file imports this module.
By convention the dash suffix means "internal". The two vars hold where
to write and whether to also echo.

`log-init` sets them. The expression `(not= echo? false)` is a careful
default: we want echo **on** unless the caller explicitly passes
`false`. If `echo?` is `nil` (omitted), `(not= nil false)` is `true`
(on); if the caller passes `false`, it's `false` (off). Writing
`(or echo? true)` would have been wrong — it could never be turned off.

Now the core logger:

```janet
(defn log
  ``Write one structured line to the daemon log. level is a keyword
  like :info, :warn, or :error. tag is a short component name string.``
  [level tag fmt & args]
  (def msg (string/format ;(array/push @[fmt] ;args)))
  (def line (string/format "%s %-5s [%s] %s"
                            (iso-timestamp) (string/ascii-upper (string level))
                            tag msg))
  (when log-path (append-line log-path line))
  (when log-echo (print line)))
```

The interesting line is the first one in the body. We want `log` to
accept a format string and its arguments the way `string/format` does —
`(log :info "scheduler" "job '%s' ran in %ds" name secs)` — and apply
`string/format` to them. The pieces:

- `& args` collects the format arguments into an array.
- `@[fmt]` is a one-element array holding the format string.
- `(array/push @[fmt] ;args)` pushes... wait — it's the `;` that matters.
  `;args` is the **splat / spread** operator: it splices the elements of
  `args` in as individual arguments. So if `args` is `@["backup" 4]`,
  then `(array/push @[fmt] ;args)` yields `@[fmt "backup" 4]`.
- The outer `;` does it again: `(string/format ;that-array)` splats the
  array back out as positional arguments to `string/format`, exactly as
  if we'd written `(string/format fmt "backup" 4)`.

> **Why splat twice?** Because `log` receives the format pieces as a
> *collection* (`args`) but `string/format` wants them as *separate
> arguments*. `;` is the bridge between "a list of things" and "things
> passed individually". You'll use it constantly in Janet anywhere you
> need to forward a variable number of arguments. Read `;xs` as
> "unpack `xs` right here".

The format string `"%s %-5s [%s] %s"` produces lines like:

```
2026-06-20T14:03:05 INFO  [scheduler] job 'backup' started
```

`%-5s` is a left-justified, minimum-5-wide string, so `INFO`, `WARN`,
and `ERROR` line up in a column. `(string/ascii-upper (string level))`
turns the keyword `:info` into the text `INFO` (first `string` converts
the keyword to `"info"`, then we uppercase).

Finally, three thin convenience wrappers, themselves using splat to
forward their args:

```janet
(defn log/info [tag fmt & args] (log :info tag fmt ;args))
(defn log/warn [tag fmt & args] (log :warn tag fmt ;args))
(defn log/error [tag fmt & args] (log :error tag fmt ;args))
```

> **A naming note.** `log/info` looks like it's calling into a `log`
> module, but the `/` here is just an ordinary character in the symbol
> name — Janet allows `/` in identifiers. We're using it cosmetically to
> group related functions. (When `/` appears in `os/time`, that *is* the
> module convention, but the language doesn't enforce a difference; it's
> all just symbols.)

Checkpoint — see a real log line, both echoed and on disk:

```janet
$ janet -e '(import ./src/util :as u) \
  (u/log-init "/tmp/janetd-tut/daemon.log" true) \
  (u/log/info "demo" "hello %s, run #%d" "world" 7) \
  (u/log/warn "demo" "careful now") \
  (print "--- file contents ---") \
  (print (slurp "/tmp/janetd-tut/daemon.log"))'
2026-06-20T14:10:00 INFO  [demo] hello world, run #7
2026-06-20T14:10:00 WARN  [demo] careful now
--- file contents ---
2026-06-20T14:10:00 INFO  [demo] hello world, run #7
2026-06-20T14:10:00 WARN  [demo] careful now
```

The lines appear twice: once echoed live (because we passed `true`) and
once when we slurp the file back. That's the whole `util.janet`. You've
now met `def`/`var`/`set`, `defn`/`fn`, `&opt`/`&`/`;`, `cond`/`when`/
`unless`/`if`/`or`/`not=`, `try`, struct/array/table literals and
indexing, and a dozen stdlib functions. Everything else builds on this.

---

## Part 2 — `schedule.janet`: data-as-config, `case`, and `error`

Now we teach the daemon *when* to run things. Rather than invent a
cron-string mini-language, we'll represent a schedule as a plain Janet
tuple whose first element is a keyword tag:

```janet
[:every 30]        # every 30 seconds
[:daily "02:30"]   # once a day at 02:30 local time
[:hourly 15]       # every hour, at minute 15
[:once]            # one time, shortly after the daemon starts
[:manual]          # never on a timer; only when explicitly triggered
```

> **Why tuples-with-a-tag?** This is a hugely common Lisp pattern: use a
> small immutable data structure, tagged by a leading keyword, as a tiny
> typed command. It's trivially serializable, trivially pattern-matched
> with `case`, and reads naturally in a config file (which, remember, is
> just Janet source). You'll see the same shape again later when we
> design the control-socket protocol and the job-result records.

This module exports three functions: `validate` (is this a well-formed
schedule?), `next-run` (given a schedule and when it last ran, when
should it run next?), and `backoff-seconds` (a retry-timing helper).

Create `src/schedule.janet` with a header, then build it up.

### Validating with `case` and raising errors

```janet
(defn- parse-hhmm [s]
  (def parts (string/split ":" s))
  (unless (= 2 (length parts))
    (error (string/format "bad HH:MM time: %q" s)))
  (def h (scan-number (parts 0)))
  (def m (scan-number (parts 1)))
  (unless (and h m (<= 0 h 23) (<= 0 m 59))
    (error (string/format "bad HH:MM time: %q" s)))
  [h m])
```

`defn-` (trailing dash, like `var-`) defines a **private** function —
usable inside this file, not exported. This is a helper that turns
`"02:30"` into the tuple `[2 30]`, validating as it goes.

New things:

- `scan-number` parses a string into a number, returning `nil` if it
  isn't numeric (so `(scan-number "0x")` is `nil`, not an error).
- `error` **raises**. It's how Janet signals failure; somewhere up the
  call stack a `try` will catch it (or the program aborts with a
  stack trace). We raise with a descriptive message built by
  `string/format`.
- `(<= 0 h 23)` is a **chained comparison**: Janet's comparison
  operators take any number of arguments and check the whole chain, so
  this reads literally as "0 ≤ h ≤ 23". Elegant and exactly what we
  mean.
- `(and h m ...)` guards against the `nil`s from a failed
  `scan-number` before the range checks run.

Now the public validator, our first real use of `case`:

```janet
(defn validate
  ``Raise a descriptive error if `sched` is not a recognized schedule
  spec. Returns sched unchanged on success.``
  [sched]
  (unless (indexed? sched)
    (error (string/format "schedule must be a tuple/array, got %q" sched)))
  (def kind (first sched))
  (case kind
    :every (unless (and (= 2 (length sched)) (number? (sched 1)) (pos? (sched 1)))
             (error "[:every seconds] requires a positive number of seconds"))
    :daily (do
             (unless (= 2 (length sched))
               (error "[:daily \"HH:MM\"] requires a time string"))
             (parse-hhmm (sched 1)))
    :hourly (unless (and (= 2 (length sched)) (number? (sched 1)) (<= 0 (sched 1) 59))
              (error "[:hourly minute] requires a minute between 0 and 59"))
    :once (unless (= 1 (length sched)) (error "[:once] takes no arguments"))
    :manual (unless (= 1 (length sched)) (error "[:manual] takes no arguments"))
    (error (string/format "unknown schedule kind: %q" kind)))
  sched)
```

`case` compares its first argument against each candidate using
identity/equality and runs the matching branch: `(case x v1 result1 v2
result2 ... default)`. The pairs are value-then-result; a final lone
expression (here the `error` call) is the default when nothing matched.
Because keywords are interned, comparing against `:every`, `:daily`,
etc. is fast and reads cleanly.

A few details:

- `indexed?` is true for tuples and arrays (things you can index by
  number) — we accept either.
- `(first sched)` grabs the tag. `(sched 1)` grabs the argument.
- `:daily`'s branch uses `(do ...)` to group two expressions (the length
  check *and* a `parse-hhmm` call that doubles as validation of the time
  string). `do` evaluates several expressions and returns the last;
  you reach for it whenever a single slot needs to hold multiple steps.
- The function returns `sched` unchanged at the end, so you can use it
  as a pass-through filter: `(validate s)` either throws or hands `s`
  right back.

Checkpoint — valid specs pass silently, bad ones throw with a clear
message. We'll use `try` to catch and print the errors so one script can
show several:

```janet
$ janet -e '(import ./src/schedule :as s) \
  (each ok [[:every 30] [:daily "02:30"] [:hourly 15] [:once] [:manual]] \
    (s/validate ok)) \
  (print "all valid specs passed") \
  (each bad [[:every -5] [:daily "25:99"] [:bogus]] \
    (try (s/validate bad) ([e] (print "rejected: " e))))'
all valid specs passed
rejected: [:every seconds] requires a positive number of seconds
rejected: bad HH:MM time: "25:99"
rejected: unknown schedule kind: :bogus
```

### Computing the next run time

This is the brain of scheduling. Given a schedule, the timestamp it last
ran (`nil` if never), and "now", return the next Unix time it should
run — or `nil` if it shouldn't run on a timer at all.

```janet
(defn next-run
  ``Given a schedule spec, the unix time it was last run (or nil if
  never), and the current time, return the next unix time the job
  should run, or nil if it should not be scheduled automatically
  (e.g. :manual, or :once that has already run).``
  [sched last-run now]
  (case (first sched)
    :every
    (do
      (def interval (sched 1))
      (if last-run (+ last-run interval) now))

    :daily
    (do
      (def hm (parse-hhmm (sched 1)))
      (def hh (hm 0))
      (def mm (hm 1))
      (def d (os/date now true))
      (def midnight (- now (* (d :hours) 3600) (* (d :minutes) 60) (d :seconds)))
      (def today-at (+ midnight (* hh 3600) (* mm 60)))
      (def candidate (if (>= today-at now) today-at (+ today-at 86400)))
      (if (and last-run (<= candidate last-run))
        (+ candidate 86400)
        candidate))

    :hourly
    (do
      (def mm (sched 1))
      (def d (os/date now true))
      (def hour-start (- now (* (d :minutes) 60) (d :seconds)))
      (def this-hour-at (+ hour-start (* mm 60)))
      (def candidate (if (>= this-hour-at now) this-hour-at (+ this-hour-at 3600)))
      (if (and last-run (<= candidate last-run))
        (+ candidate 3600)
        candidate))

    :once
    (if last-run nil now)

    :manual
    nil

    (error (string/format "unknown schedule kind: %q" (first sched)))))
```

Each branch is just arithmetic on Unix timestamps (plain integers of
seconds), which makes this very testable. Let's read the tricky ones.

**`:every`** is the simplest and the most important design decision in
the whole scheduler. If the job has run before, the next run is
`last-run + interval` — measured **from when it last started**, not from
a fixed wall-clock grid. If it has never run (`last-run` is `nil`), it
runs *now*. Because `last-run` is persisted to disk (Part 1's
`write-jdn`), restarting the daemon doesn't fire a burst of "overdue"
runs — it just picks up the cadence where it left off.

**`:daily`** has to find "the next occurrence of HH:MM in local time".
We compute local midnight by subtracting today's elapsed hours, minutes,
and seconds from `now` (all from `os/date`), then add the target
HH:MM back on. If that instant is still in the future today, that's our
candidate; otherwise it's tomorrow (`+ 86400`, the seconds in a day).
The final `if` handles the "already ran at this slot" case: if the
candidate is at or before `last-run`, push to the next day so we don't
double-fire.

**`:hourly`** is the same shape at hourly granularity (`3600` seconds).

**`:once`** returns `now` if it has never run, and `nil` forever after —
a one-shot. **`:manual`** always returns `nil`: it never self-schedules.
Both still respond to manual triggers later; returning `nil` only means
"don't set a timer".

> **Why return `nil` for "never"?** It gives the scheduler loop a single,
> uniform signal: "there is no next timed run; just wait for a manual
> trigger." We'll see in Part 5 that the loop treats a `nil` delay as
> "block indefinitely until triggered." One representation, two
> schedule kinds, no special cases in the caller.

### Exponential backoff

The last helper decides how long to wait between retry attempts. We want
each retry to wait longer than the last (so a flapping service gets some
breathing room) but not unboundedly long.

```janet
(defn backoff-seconds
  ``Exponential backoff with a cap, used between retry attempts.
  attempt is 1 for the first retry, 2 for the second, etc.``
  [base attempt &opt max-backoff]
  (def capped (or max-backoff (* base 32)))
  (min capped (* base (math/pow 2 (dec attempt)))))
```

With `base = 5`: attempt 1 waits `5 * 2^0 = 5`s, attempt 2 waits
`5 * 2^1 = 10`s, attempt 3 waits `20`s, and so on, capped at `base * 32
= 160`s. `math/pow` is exponentiation, `dec` subtracts one, `min` clamps
to the cap.

Checkpoint — exercise `next-run` and `backoff-seconds`:

```janet
$ janet -e '(import ./src/schedule :as s) \
  (def now (os/time)) \
  (print "every, first run delay: " (- (s/next-run [:every 60] nil now) now)) \
  (print "every, subsequent delay: " (- (s/next-run [:every 60] now now) now)) \
  (print "once, never: " (- (s/next-run [:once] nil now) now)) \
  (print "once, already ran: " (s/next-run [:once] now now)) \
  (print "manual: " (s/next-run [:manual] nil now)) \
  (print "backoff 1..4: " \
    (s/backoff-seconds 5 1) " " (s/backoff-seconds 5 2) " " \
    (s/backoff-seconds 5 3) " " (s/backoff-seconds 5 10))'
every, first run delay: 0
every, subsequent delay: 60
once, never: 0
once, already ran: nil
manual: nil
backoff 1..4: 5 10 20 160
```

(With `print`, a `nil` shows up as an empty value, so those two lines
will actually look blank after the colon — `once, already ran: ` — when
you run it. The returned value is genuinely `nil`; swap `print` for `pp`
if you want to see the word.)

`:every` with no history fires immediately (delay 0); with history it
waits the full interval. `:once` and `:manual` return `nil` exactly when
they should. Backoff doubles then caps at 160. The scheduler now knows
*when*; next we teach it *how* to actually run something.

---

## Part 3 — `runner.janet`: processes, the event loop, fibers, and channels

This is the most conceptually dense part, and the most fun. We're going
to spawn a child process, capture everything it prints, and — the tricky
bit — kill it if it runs too long, all without blocking the rest of the
daemon. To do that we need Janet's concurrency model, so let's build up
to it.

### Importing a sibling module

The file starts by pulling in our utilities:

```janet
### runner.janet
### Executes a single attempt of a job: spawns the process, captures
### combined stdout+stderr to a log file, enforces an optional timeout,
### and reports back exit status.

(import ./util :as u)
```

Note the path is `./util`, **not** `./src/util`. Imports are resolved
relative to the importing file, and both files live in `src/`, so a
sibling is just `./util`. (When we ran REPL one-liners from the project
root in earlier parts, we used `./src/util` because *the REPL's*
location was the root.)

### Two small `defn-` helpers first

```janet
(defn- build-argv
  ``Wrap `argv` so it executes inside `cwd`, if given. Uses a small
  shell shim since os/spawn has no native working-directory option.``
  [argv cwd]
  (if cwd
    ["sh" "-c" "cd \"$1\" && shift && exec \"$0\" \"$@\"" (argv 0) cwd ;(slice argv 1)]
    argv))
```

A job may want to run in a particular working directory. Janet's
`os/spawn` (which we're about to meet) has no built-in "cwd" option, so
we improvise with a tiny shell shim. If no `cwd` is requested we return
`argv` unchanged.

When a `cwd` *is* requested, we build a new argv that runs `sh -c` with
a script that `cd`s into the directory and then `exec`s the original
command. The mechanics of the shim:

- `sh -c SCRIPT A B C...` runs `SCRIPT` with `A` as `$0`, `B` as `$1`,
  and so on.
- Our script is `cd "$1" && shift && exec "$0" "$@"`. We pass the
  original command name as `$0`, the cwd as `$1`, and the original
  arguments as `$2`, `$3`, ... So it changes into the cwd, `shift`s the
  cwd off the argument list, and `exec`s `$0` (the command) with the
  remaining `"$@"`.
- `(argv 0)` is the command; `cwd` is the directory; `;(slice argv 1)`
  splats the rest of the original arguments into place. (There's our
  splat operator `;` from Part 1 again, doing exactly the "unpack this
  collection as individual arguments" job.)

> You don't need to memorize the shim; you need to recognize the *shape*
> of the move: when a library primitive is missing a feature, wrapping
> the call in a thin shell layer is often the pragmatic fix, and Janet's
> splat makes assembling the argv painless.

```janet
(defn- build-env
  ``Merge any job-specific environment variables on top of the
  daemon's own environment.``
  [extra-env]
  (if (and extra-env (not (empty? extra-env)))
    (merge (os/environ) extra-env)
    nil))
```

`os/environ` returns the daemon's whole environment as a table.
`merge` produces a new table combining several — later ones win — so a
job's `:env` overrides inherited variables. If the job specifies no
extra env, we return `nil` (meaning "inherit the parent's environment
unchanged"), which we'll use to pick the spawn flags below.

### Interlude: the event loop, fibers, and channels

Before the main function, you need three Janet concepts.

**Fibers** are Janet's lightweight cooperative threads. A fiber is a
function whose execution can be suspended and resumed. They are *not* OS
threads — there's one OS thread, and fibers take turns. They yield
control at well-defined points (mostly when they'd block on I/O).

**The event loop** (the `ev/` module) schedules fibers. When you start
Janet, there's an event loop ready. `ev/spawn` launches a fiber onto it;
`ev/go` does the same and hands you a reference to the fiber. When a
fiber does something that would block — sleep, read a socket, wait on a
process — it suspends, the loop runs other ready fibers, and resumes the
first one when its event is ready. This is **async concurrency without
callbacks**: you write straight-line code, and the suspensions are
invisible.

**Channels** (`ev/chan`) are how fibers communicate and synchronize. A
channel is a queue with a capacity. `(ev/give ch v)` puts a value in
(blocking the giver if it's full); `(ev/take ch)` removes one (blocking
the taker if it's empty). "Blocking" here means "suspends this fiber and
lets others run" — not "freezes the program".

A 20-second demo you can run to feel it:

```janet
$ janet -e '\
  (def ch (ev/chan 1)) \
  (ev/spawn (ev/sleep 0.2) (ev/give ch :from-fiber)) \
  (print "main: waiting for a value...") \
  (print "main: got " (ev/take ch))'
main: waiting for a value...
main: got from-fiber
```

(`print` shows `from-fiber` without the colon; the value on the channel
really is the keyword `:from-fiber`.)

The main code calls `ev/take` on an empty channel, suspends, the spawned
fiber sleeps 200ms and gives a value, and the main code wakes up with it.
No threads, no locks, no callbacks.

The single most useful primitive for us is **`ev/select`**, which waits
on *several* channel operations at once and tells you which one happened
first:

```janet
(ev/select ch-a ch-b)
# => [:take ch-a value]   if a value arrived on ch-a first
# => [:take ch-b value]   if it arrived on ch-b first
```

The result is a tuple whose second element is the channel that won. That
"whoever fires first wins" behavior is exactly how we'll implement a
timeout: race the process-finished signal against a timer.

### Spawning a process and capturing its output

Now `run-attempt`, the heart of the file. It's long, so we'll build and
explain it in chunks; assemble them into one `defn` as we go.

```janet
(defn run-attempt
  ``Run one attempt of a job. `job` is the job spec table (must have
  :command, may have :cwd, :env, :timeout). `log-path` is the file
  attempt output is written to (overwritten if it exists). Returns a
  result table:
    {:exit-code int-or-nil  :timed-out bool  :error string-or-nil
     :started-at unix-ts    :ended-at unix-ts}
  exit-code is nil only when the process could not even be spawned, or
  it never finished and the runner explicitly killed it.``
  [job log-path]
  (def started-at (u/now-unix))
  (def argv (build-argv (job :command) (job :cwd)))
  (def extra-env (build-env (job :env)))
  (def flags (if extra-env :ep :p))
  (def spawn-opts (table ;(if extra-env (kvs extra-env) [])))
  ...
```

Setup. We record the start time, build the (possibly cwd-wrapped) argv,
and compute the environment. Then two lines that prepare the call to
`os/spawn`:

- **`flags`.** `os/spawn`'s second argument is a string of single-letter
  flags. `p` means "search `$PATH` for the program" (so we can say
  `"echo"` instead of `/bin/echo`). `e` means "an environment table is
  provided". So if we have extra env we pass `:ep`, otherwise just `:p`.
- **`spawn-opts`.** `os/spawn`'s third argument is a table of options.
  When we have an environment, it must go in as key/value pairs in that
  table. `kvs` turns a table into a flat `[k1 v1 k2 v2 ...]` array, and
  `(table ;that)` splats it into a fresh table. When there's no env, we
  start with an empty table. (We'll add `:out`/`:err` to it shortly.)

```janet
  (u/ensure-dir (u/dirname log-path))
  (def logf (file/open log-path :w))
  (unless logf
    (break {:exit-code nil :timed-out false
            :error (string/format "could not open log file %q" log-path)
            :started-at started-at :ended-at (u/now-unix) :log-path log-path}))
```

We make sure the log's directory exists (Part 1's `ensure-dir`), then
open the log file for writing (`:w` truncates/creates). If that fails we
**`break`** out of the function early with an error result. `break`
inside a function body returns immediately with the given value — handy
for early exits without nesting the rest of the body in an `else`.

> **Why a result *table* instead of throwing?** A failed attempt is a
> normal, expected outcome for a job runner — not an exceptional
> condition. So `run-attempt` never throws for job failure; it always
> returns a uniform result table describing what happened (exit code,
> timed out, error string). The caller inspects fields rather than
> wrapping every call in `try`. Reserve exceptions for the truly
> unexpected.

```janet
  (defn header [s] (file/write logf s) (file/write logf "\n"))
  (header (string/format "# janetd job=%s attempt-log started=%s"
                          (job :name) (u/iso-timestamp started-at)))
  (header (string/format "# command: %s" (string/join (job :command) " ")))
  (header "# ---- output ----")
  (file/flush logf)

  (put spawn-opts :out logf)
  (put spawn-opts :err logf)
```

A nice touch: each attempt's log file starts with a few comment lines
recording what ran and when. Notice `header` is a **function defined
inside a function** — Janet closures can be local. It closes over
`logf`, so each call writes a line plus newline to that file. We
`file/flush` to make sure the header is on disk before the child starts
appending.

Then the crucial two `put`s: we add `:out logf` and `:err logf` to the
spawn options. This redirects the child's **stdout and stderr both into
our log file**, so a job's normal output and its error output are
interleaved in one place — exactly what you want when debugging "what
did this job actually do".

### The timeout race: the payoff

Here's the part the whole concurrency interlude was for:

```janet
  (def result
    (try
      (do
        (def proc (os/spawn argv flags spawn-opts))
        (def done (ev/chan 1))
        (ev/spawn
          (def code (os/proc-wait proc))
          (ev/give done code))
        (def timeout (job :timeout))
        (if timeout
          (do
            (def timed-out-chan (ev/chan 1))
            (ev/spawn (ev/sleep timeout) (ev/give timed-out-chan true))
            (def selected (ev/select done timed-out-chan))
            (def chosen-chan (selected 1))
            (if (= chosen-chan timed-out-chan)
              (do
                (os/proc-kill proc)
                (ev/take done) # reap the process, avoid a zombie
                {:exit-code nil :timed-out true :error nil})
              {:exit-code (selected 2) :timed-out false :error nil}))
          {:exit-code (ev/take done) :timed-out false :error nil}))
      ([err] {:exit-code nil :timed-out false :error (string err)})))
```

Read it slowly:

1. `(os/spawn argv flags spawn-opts)` launches the child and returns a
   process object immediately — it does **not** wait for it to finish.
2. We make a channel `done` and spawn a fiber whose only job is to call
   `os/proc-wait` (which blocks until the child exits, yielding to the
   loop meanwhile) and then `ev/give` the exit code onto `done`. So
   "the process finished" becomes "a value appeared on `done`".
3. **If there's no timeout**, we simply `(ev/take done)` — block until
   the process finishes — and report its exit code. Done.
4. **If there's a timeout**, we set up a *second* channel `timed-out-chan`
   and a fiber that sleeps for `timeout` seconds and then gives a value
   on it. Now we have two fibers racing to put something on a channel:
   one when the process finishes, one when the timer expires.
5. `(ev/select done timed-out-chan)` blocks until *either* fires and
   tells us which. `(selected 1)` is the winning channel.
6. If the **timer** won, the process is still running, so we
   `os/proc-kill` it. Then — easy to forget — we `(ev/take done)` to
   collect the now-dead process's exit status. Without that, the killed
   child becomes a **zombie** (a finished process whose status nobody
   read). We report `:timed-out true`.
7. If the **process** won, `(selected 2)` is the value it gave (the exit
   code), and we report it normally.

The whole thing is wrapped in `try`: if `os/spawn` itself fails (e.g.
the program doesn't exist), the `([err] ...)` branch returns an error
result instead of crashing.

> **Why a race instead of a "deadline" API?** Janet does have
> deadline/cancel primitives, but the explicit two-channel race is the
> most *legible* way to express "whichever happens first", and it
> generalizes: add a third channel (say, a manual-cancel signal) and
> `ev/select` handles it with no restructuring. This pattern —
> **model each event as a value on a channel, then `ev/select` the
> ones you care about** — is the workhorse of concurrent Janet, and
> you'll see it again in the scheduler.

### Finishing up

```janet
  (def ended-at (u/now-unix))
  (header (string/format "# ---- end (exit=%V timed-out=%V duration=%ds) ----"
                          (or (result :exit-code) "n/a") (result :timed-out)
                          (- ended-at started-at)))
  (file/close logf)

  (merge result {:started-at started-at :ended-at ended-at :log-path log-path}))
```

We write a footer to the log, close the file, and return the result
table enriched with timing and the log path (via `merge`, which here
adds fields to a copy of `result`).

> **One format detail.** The footer uses `%V` (not `%s`). `%s` in
> `string/format` only accepts string-like values and *errors* on a
> number or a boolean; `%V` accepts *anything* and prints its default
> representation. Since `exit-code` might be a number or the string
> `"n/a"`, and `timed-out` is a boolean, `%V` is the safe choice. This
> is a real papercut: an early version used `%s` and threw "bad slot,
> expected string, got 0" the first time a job exited with code 0.

### Checkpoint — run real processes

Save the assembled file, then exercise every path. Put this script
**in your project root** (save it as `janetd/try-runner.janet`) and run
it from there — because `(import ./src/runner ...)` resolves relative to
the script file's own location, a script in `/tmp` couldn't find it:

```janet
(import ./src/runner :as r)

(print "--- success ---")
(def ok (r/run-attempt {:name "ok" :command ["echo" "hi there"]}
                       "/tmp/janetd-tut/ok.log"))
(print "exit=" (ok :exit-code) " timed-out=" (ok :timed-out))
(print (slurp "/tmp/janetd-tut/ok.log"))

(print "--- failure (exit 7) ---")
(def bad (r/run-attempt {:name "bad" :command ["sh" "-c" "echo oops 1>&2; exit 7"]}
                        "/tmp/janetd-tut/bad.log"))
(print "exit=" (bad :exit-code))

(print "--- timeout (sleep 5, limit 1) ---")
(def t0 (os/time))
(def slow (r/run-attempt {:name "slow" :command ["sleep" "5"] :timeout 1}
                         "/tmp/janetd-tut/slow.log"))
(print "timed-out=" (slow :timed-out) " wall-seconds=" (- (os/time) t0))

(print "--- bad command ---")
(def nope (r/run-attempt {:name "nope" :command ["this-cmd-does-not-exist"]}
                         "/tmp/janetd-tut/nope.log"))
(print "error=" (nope :error))
```

```sh
$ janet /tmp/try-runner.janet
--- success ---
exit=0 timed-out=false
# janetd job=ok attempt-log started=2026-06-20T14:20:00
# command: echo hi there
# ---- output ----
hi there
# ---- end (exit=0 timed-out=false duration=0s) ----

--- failure (exit 7) ---
exit=7
--- timeout (sleep 5, limit 1) ---
timed-out=true wall-seconds=1
--- bad command ---
error=("this-cmd-does-not-exist"): No such file or directory
```

The key things to notice: combined stdout+stderr land in the log with a
tidy header/footer; a non-zero exit is captured as a number; the timeout
case returns after ~1 second (not 5), proving we killed the `sleep`; and
an unspawnable command yields an `:error` string instead of a crash.

---

## Part 4 — `alerts.janet`: comprehensions, `cond` returning data, and fire-and-forget

A scheduler that runs jobs but stays silent when they fail isn't much
use. This module decides *whether an attempt should raise an alert* and
*delivers* alerts (to a log file and an optional external hook). It also
introduces Janet's list comprehension, `seq`.

Header and imports:

```janet
### alerts.janet
### Detecting failure conditions (from exit codes and from log
### content) and dispatching alerts about them.

(import ./util :as u)
```

### A `def` that holds data, and scanning text with `seq`

Not every failure shows up as a non-zero exit code. Plenty of programs
print `ERROR: ...` and then exit 0 anyway. So we keep a list of
failure-signalling substrings:

```janet
(def default-patterns
  ``Substrings that, if found in a job's captured output, are treated
  as a failure signal even when the process exits 0. Matching is
  case-insensitive.``
  ["error" "exception" "traceback" "panic" "fatal" "segmentation fault"])
```

`def` at the top level of a module creates an exported binding — here a
plain tuple of strings, with a docstring. (Yes, `def` values can have
docstrings too, not just functions.)

Now the scanner:

```janet
(defn scan-text
  ``Return the list of configured patterns that occur in `text`
  (case-insensitive substring search). Empty if none match.``
  [text patterns]
  (def lower (string/ascii-lower text))
  (seq [p :in patterns
        :when (string/find (string/ascii-lower p) lower)]
    p))
```

`seq` is Janet's **list comprehension** — it builds an array by
iterating and collecting. The shape is `(seq [bindings...] body)`, and
it's easiest to read as "for each `p` in `patterns`, when the condition
holds, collect `p`":

- `[p :in patterns]` iterates `p` over the elements of `patterns`.
- `:when (...)` filters: only iterations where the expression is truthy
  contribute to the result.
- The body `p` is what gets collected each time.

`string/find` returns the index of a substring, or `nil` if absent. We
lowercase both the text and each pattern so matching is
case-insensitive (`ERROR`, `Error`, and `error` all hit). The result is
the array of patterns that matched — empty if none did.

> **Comprehensions vs. map/filter.** We could have written this as a
> `filter` over `patterns`. `seq` with `:when` is the idiomatic Janet
> way when you're iterating-and-collecting with a condition; it reads top
> to bottom like a sentence and supports multiple bindings and `:when`
> clauses in one form. Keep both tools; reach for `seq` when the loop
> body is doing real work.

A thin file-reading wrapper, with the nil-guarding we discussed in
Part 1:

```janet
(defn scan-log-file
  ``Like scan-text, but reads the file at `path` first. Returns []
  if `path` is nil or the file can't be read.``
  [path patterns]
  (if (and path (os/stat path))
    (scan-text (slurp path) patterns)
    []))
```

The `(and path (os/stat path))` guard matters: callers sometimes pass a
result whose `:log-path` is `nil` (e.g. a spawn that failed before any
log existed), and `slurp` on `nil` would throw. Defensive, cheap,
correct.

### Fire-and-forget hooks, destructuring, and a GC trap

When an alert fires, we append it to a log and optionally run a
user-configured command (a Slack webhook curl, a `mail` invocation,
whatever). We hand the alert details to that command as environment
variables so the script can use them.

```janet
(defn- run-hook
  ``Fire-and-forget a shell hook command with alert details passed as
  environment variables, so it can be a script, a curl invocation, a
  `mail` command, a desktop notifier, etc. Reaps the process in the
  background once it finishes; the caller does not wait for it.``
  [hook-argv fields]
  (try
    (do
      (def extra (table ;(mapcat (fn [[k v]] [(string "JANETD_" k) (string v)])
                                  (pairs fields))))
      (def env (merge (os/environ) extra))
      (def proc (os/spawn hook-argv :ep env))
      (ev/spawn (try (os/proc-wait proc) ([_] nil))))
    ([err] (u/log/error "alerts" "alert hook failed: %V" err))))
```

The env-building line is dense; let's expand it:

- `(pairs fields)` turns the alert table `{:job "backup" :reason "..."}`
  into a list of `[key value]` pairs: `[[:job "backup"] [:reason "..."]]`.
- `(fn [[k v]] ...)` is an anonymous function that **destructures** its
  argument: instead of taking one parameter and indexing it, the
  parameter pattern `[k v]` binds `k` and `v` to the two elements of
  each pair. Destructuring works in function params, `def`, and `let`
  bindings — it's everywhere in idiomatic Janet.
- For each pair we produce a two-element array
  `[(string "JANETD_" k) (string v)]` — prefixing the key (so `:job`
  becomes the env var `JANETD_job`) and stringifying the value.
- `mapcat` is `map` followed by concatenation: it maps the function over
  the pairs and flattens the resulting two-element arrays into one flat
  `[k1 v1 k2 v2 ...]` sequence.
- `(table ;that)` splats that flat sequence into a fresh table — our
  extra environment variables.

Then we `merge` them onto the daemon's environment and `os/spawn` the
hook with flags `:ep` (PATH search + env table).

> **The GC trap — a genuinely surprising bug.** Look at the last line
> inside the `do`:
>
> ```janet
> (ev/spawn (try (os/proc-wait proc) ([_] nil)))
> ```
>
> Why spawn a fiber just to wait on a process whose result we don't
> care about? Because of how Janet manages child processes. A process
> object that nobody waits on, and that becomes **unreferenced**, can be
> reaped by the garbage collector — and when the GC collects a live
> child process, it *kills it*. If we spawned the hook and immediately
> returned, `proc` would go out of scope, and a later GC cycle could
> terminate our webhook mid-flight. Spawning a tiny fiber that holds a
> reference to `proc` and calls `os/proc-wait` keeps the process alive
> until it finishes *and* reaps it (no zombie). The inner `try` swallows
> the rare case where waiting itself errors.
>
> We discovered this the hard way: in an earlier version the
> `--background` daemon launcher spawned the detached daemon and exited,
> and the daemon was silently killed by the parent's GC a moment later.
> The fix in that case was a spawn flag (`d`, "detached"); here it's the
> keep-a-reference-and-wait fiber. **Whenever you `os/spawn` something
> you don't immediately `os/proc-wait`, ask who's keeping it alive.**

The whole thing is wrapped in `try` so a broken hook command logs an
error rather than taking down the alerting path.

### Dispatch, and `cond` that returns data

```janet
(defn dispatch
  ``Record and (optionally) deliver an alert. `config` is the global
  daemon config table; `fields` is a struct/table describing the
  alert, e.g. {:job "backup" :reason "exhausted retries" :exit-code 1}.
  Alerts are always appended to alerts.log; if `config` has an
  :alert-command, that command is also run with JANETD_* env vars.``
  [config fields]
  (def line (string/format "%s job=%V reason=%V exit-code=%V log=%V"
                            (u/iso-timestamp) (fields :job) (fields :reason)
                            (fields :exit-code) (fields :log-path)))
  (u/append-line (config :alerts-log) line)
  (u/log/warn "alert" "%s" line)
  (when (config :alert-command)
    (run-hook (config :alert-command) fields)))
```

`dispatch` formats a one-line summary, appends it to the alerts log,
also logs it through our Part 1 logger at WARN level, and — only if the
config defines an `:alert-command` — fires the external hook. (Again
`%V` everywhere, since `exit-code` may be `nil`.)

Finally, the decision function. This is a lovely example of `cond` used
not for side effects but to **compute and return a value** — here, the
alert fields table, or `nil` if no alert is warranted:

```janet
(defn evaluate-attempt
  ``Decide whether a completed job attempt should raise an alert.
  Returns nil if everything looks fine, or a fields table suitable for
  `dispatch` if not. `job` may carry its own :alert-patterns,
  otherwise `global-patterns` is used.``
  [job result global-patterns]
  (def patterns (or (job :alert-patterns) global-patterns))
  (def hits (scan-log-file (result :log-path) patterns))
  (cond
    (result :timed-out)
    {:job (job :name) :reason "timed out" :exit-code nil :log-path (result :log-path)}

    (and (result :exit-code) (not= 0 (result :exit-code)))
    {:job (job :name) :reason (string/format "exited with code %d" (result :exit-code))
     :exit-code (result :exit-code) :log-path (result :log-path)}

    (result :error)
    {:job (job :name) :reason (string "could not run: " (result :error))
     :exit-code nil :log-path (result :log-path)}

    (not (empty? hits))
    {:job (job :name)
     :reason (string/format "output matched pattern(s): %s" (string/join hits ", "))
     :exit-code (result :exit-code) :log-path (result :log-path)}

    nil))
```

The priority order, top to bottom, is deliberate: a **timeout** is the
most serious signal, then a **non-zero exit**, then a **spawn error**,
then finally **suspicious output** even on a clean exit. The first
matching condition produces a fields table; if none match, the trailing
lone `nil` is the `cond` default and we return `nil` ("no alert").

`(or (job :alert-patterns) global-patterns)` lets a single job override
the global pattern list with its own — handy for a job where, say, the
word "warning" really does mean trouble.

> **Returning data from `cond` is a Lisp superpower.** In many languages
> you'd set a mutable `alert` variable inside an `if/else if` ladder and
> read it afterward. In Janet the `cond` *is* the value — there's no
> intermediate variable to forget to set. The caller (the scheduler)
> just writes `(when-let [a (evaluate-attempt ...)] (dispatch ... a))`.

### Checkpoint — detection and dispatch

Save the file, then (from the project root) run:

```janet
$ janet -e '(import ./src/alerts :as a) \
  (print "clean: " (a/scan-text "all good" a/default-patterns)) \
  (print "dirty: " (a/scan-text "boom: Traceback here" a/default-patterns)) \
  (print "ok-exit: " (a/evaluate-attempt {:name "j"} \
                       {:exit-code 0 :timed-out false :log-path nil} a/default-patterns)) \
  (def fields (a/evaluate-attempt {:name "j"} \
                {:exit-code 7 :timed-out false :log-path nil} a/default-patterns)) \
  (print "bad-exit: " (string/format "%q" fields)) \
  (a/dispatch {:alerts-log "/tmp/janetd-tut/alerts.log"} fields) \
  (print "--- alerts.log ---") \
  (print (slurp "/tmp/janetd-tut/alerts.log"))'
clean: @[]
dirty: @[traceback]
ok-exit: nil
bad-exit: {:exit-code 7 :job "j" :reason "exited with code 7"}
2026-06-20T14:30:00 WARN  [alert] 2026-06-20T14:30:00 job=j reason=exited with code 7 exit-code=7 log=
--- alerts.log ---
2026-06-20T14:30:00 job=j reason=exited with code 7 exit-code=7 log=
```

A few things to read carefully against what you'll actually see:

- `scan-text` returns a mutable array; with `print` you'd literally see
  `<array 0x...>` (its pointer), not `@[traceback]`. Use `pp` (as shown
  conceptually above) to see the contents. The empty/non-empty
  distinction is the point.
- `evaluate-attempt`'s fields come out as an **immutable struct**
  `{...}` — note there's no `:log-path` key in the printed struct even
  though we passed `:log-path nil`, because **struct and table literals
  silently drop keys whose value is `nil`**. That's a Janet rule worth
  burning in: `{:a nil}` is the empty struct `{}`. (`dispatch` still
  prints `log=` with nothing after it, because it formats the *looked-up*
  value, and a missing key also reads back as `nil`.)
- `dispatch` both appends to the alerts log *and* emits a live WARN line
  through the Part 1 logger — that's the extra `WARN [alert] ...` line
  before the `--- alerts.log ---` separator.

A clean string matches nothing; a "Traceback" hits the pattern; a 0-exit
attempt yields `nil` (no alert); a 7-exit attempt yields a fields table
which `dispatch` then writes to the alerts log. Every piece of our
failure-detection pipeline now works in isolation. Time to assemble the
engine.

---

## Part 5 — `daemon.janet`: the engine

This is the big one — the file that turns our pieces into a running
daemon. It has five responsibilities: load and validate job configs,
persist run-state, run a scheduler loop per job (with queueing and
retries), watch its own log for trouble, and serve a control socket. We'll
take them in that order. It's long, but every piece reuses concepts you
already have; the genuinely new ideas are **one fiber per job**, a
**semaphore built from a channel**, and **loading config as code**.

Header and imports — this module sits on top of all four earlier ones:

```janet
### daemon.janet
### The core engine: loads job definitions, runs a scheduler fiber per
### job (handling waiting, queueing, retries, and alerting), and serves
### a small control socket for trigger/status/reload/stop commands.

(import ./util :as u)
(import ./schedule :as sched)
(import ./runner :as run)
(import ./alerts :as alerts)
```

### Config and job defaults

```janet
(defn default-config
  [home]
  {:home home
   :state-file (u/join-path home "state.jdn")
   :daemon-log (u/join-path home "daemon.log")
   :alerts-log (u/join-path home "alerts.log")
   :logs-dir (u/join-path home "logs")
   :control-sock (u/join-path home "control.sock")
   :max-concurrent 4
   :alert-patterns alerts/default-patterns
   :alert-command nil})
```

Given a "home" directory, this returns the full config struct with every
path derived from it. One place defines the on-disk layout.

```janet
(defn- job-defaults
  [job]
  (merge {:enabled true
          :max-retries 0
          :retry-backoff 5
          :timeout nil
          :cwd nil
          :env nil
          :alert-patterns nil}
         job))
```

`merge` with the defaults *first* and the user's `job` *second* means
the user's values win, but any field they omit gets a sane default. This
is the standard "options with defaults" idiom.

```janet
(defn validate-job
  [job]
  (unless (and (job :name) (string? (job :name)) (not (empty? (job :name))))
    (error "job is missing a non-empty :name"))
  (unless (and (job :command) (indexed? (job :command)) (not (empty? (job :command))))
    (error (string/format "job %V is missing a non-empty :command" (job :name))))
  (sched/validate (job :schedule))
  job)
```

Fail fast on malformed jobs, with messages a human can act on. It reuses
`sched/validate` from Part 2, so schedule errors surface here too.

### Loading config *as code* with `dofile`

Here's something that would be a big deal in another language and is
casual in a Lisp: our config files are *Janet programs*, and we load them
by evaluating them.

```janet
(defn load-jobs-file
  ``Evaluate a Janet config file and pull out its `jobs` (required,
  array of job spec tables) and `config` (optional, overrides for the
  global config table) top-level bindings.``
  [path]
  (def env (dofile path))
  (defn binding [sym] (when-let [b (get env (symbol sym))] (b :value)))
  (def raw-jobs (or (binding "jobs") []))
  (def jobs (map (fn [j] (validate-job (job-defaults j))) raw-jobs))
  (def names (map (fn [j] (j :name)) jobs))
  (unless (= (length names) (length (distinct names)))
    (error "duplicate job names in config"))
  {:jobs jobs :config-overrides (or (binding "config") {})})
```

- `dofile` reads and evaluates a Janet file and returns its
  **environment** — a table mapping each top-level symbol the file
  defined to information about it. So if the config file says
  `(def jobs [...])`, then `env` contains an entry for the symbol `jobs`.
- The local helper `binding` looks up a name in that environment. Each
  entry is itself a table with a `:value` field (plus source info), so
  `(b :value)` is the actual value the config bound. `when-let` runs its
  body only if the lookup found something, returning `nil` otherwise — so
  a config that omits `config` just yields `nil` and we fall back to `{}`.
- We map every raw job through `job-defaults` then `validate-job`, check
  for duplicate names with `distinct` (an array of unique values — if its
  length differs from the original, there were dupes), and return a tidy
  `{:jobs ... :config-overrides ...}`.

> **Config-as-code is powerful and has a cost.** The upside: your config
> can compute values, define helpers, use `(* 5 60)` for "5 minutes", and
> share logic — all with zero parser to write, because it's the language
> you already have. The downside is the obvious one: a config file can
> run arbitrary code, so it must be as trusted as the daemon itself. For
> a personal systemd-substitute that you write your own configs for,
> that's a fine trade. For multi-tenant config you'd want a sandbox or a
> data-only format. Know which world you're in.

### Persisted run state

```janet
(defn- load-state [config] (u/read-jdn (config :state-file) @{}))

(defn- job-state [state name]
  (get state name {:last-run nil :last-status nil :run-count 0 :fail-count 0}))

(defn- save-job-state! [state-box config name new-job-state]
  (put state-box name new-job-state)
  (u/write-jdn (config :state-file) state-box))
```

`load-state` reads the JDN state file, defaulting to a **mutable `@{}`** —
remember the Part 1 gotcha; if this were `{}` the first `put` would throw.
`job-state` fetches one job's record (or fresh zeros). `save-job-state!`
mutates the in-memory table and writes the whole thing back atomically.

> **The `!` convention.** The trailing `!` in `save-job-state!` is a
> convention (borrowed from Scheme/Clojure) signalling "this mutates
> state / has side effects". Janet doesn't enforce it; it's a courtesy to
> readers. You'll see it on the functions here that write to disk or
> mutate shared tables.

### The registry, and a channel as a wake-up signal

Each known job gets a runtime "entry" holding its current spec, a
**trigger channel** (how we wake it for a manual run), its scheduler
fiber, and a mutable status table for `STATUS` to read.

```janet
(defn- new-registry [] @{})

(defn- registry-entry [job state-box]
  (def st (job-state state-box (job :name)))
  @{:spec job
    :trigger-chan (ev/chan 1)
    :fiber nil
    :status @{:state :idle :next-run nil
              :last-run (st :last-run) :last-status (st :last-status)
              :run-count (st :run-count) :fail-count (st :fail-count)}})
```

Notice the status is **seeded from persisted state** (`st`), so after a
restart `STATUS` shows the real last-run time and counts instead of
"never". (We added this after noticing a restart wrongly reported every
job as never-run — the persisted numbers were on disk but not loaded into
the live status.)

```janet
(defn- trigger-job!
  ``Best-effort wake-up: never blocks the caller. Runs in its own
  fiber so a full channel (an already-pending trigger) just means
  this one queues up behind it rather than stalling the control
  connection that asked for it.``
  [entry]
  (ev/spawn (ev/give (entry :trigger-chan) true)))
```

To trigger a job we put a value on its trigger channel. We do it inside
`ev/spawn` so that if the channel is already full (a trigger is pending),
*this* fiber blocks, not the control connection that called us. The
caller returns instantly either way.

### Waiting for "next run or a trigger" — the race again

```janet
(defn- wait-for-next
  ``Block until either `delay` seconds have passed (if non-nil) or the
  job's trigger channel fires, whichever comes first. Returns :timer
  or :triggered. If delay is nil, only the trigger can wake us.``
  [delay trigger-chan]
  (if delay
    (do
      (def timer-chan (ev/chan 1))
      (ev/spawn (ev/sleep (max 0 delay)) (ev/give timer-chan true))
      (def selected (ev/select trigger-chan timer-chan))
      (if (= (selected 1) trigger-chan) :triggered :timer))
    (do (ev/take trigger-chan) :triggered)))
```

This is the timeout race from Part 3, reused for a different purpose: a
job's loop wants to wake up *either* when its scheduled delay elapses *or*
when someone triggers it, whichever comes first. Same pattern — spawn a
timer fiber, `ev/select` the timer against the trigger channel. If
`delay` is `nil` (a `:manual`/`:once`-already-run job), there's no timer
at all: we just `ev/take` the trigger and block until a manual trigger
arrives. **One function, both "scheduled" and "manual-only" jobs.**

### Running a job once, with queueing and retries

Now the core worker. Read the prose first, then the code.

A "run" of a job means: try it, and if it fails, retry up to
`:max-retries` times with exponential backoff, until it succeeds or we
give up. Every individual *attempt* must first acquire a slot from a
global concurrency limiter (so the whole daemon never runs more than
`:max-concurrent` attempts at once). When the run finishes we update the
job's status and, on final failure, dispatch an alert.

The concurrency limiter is a **semaphore, and we build it from a
channel**: a channel pre-filled with N tokens. To run, take a token
(blocking if none are free); when done, give it back. That's the entire
mechanism.

```janet
(defn- attempt-failed? [result]
  (or (result :timed-out)
      (result :error)
      (and (result :exit-code) (not= 0 (result :exit-code)))))

(defn- run-job-once
  ``Run `job` to completion, including retries, queueing for a free
  worker slot via `sem` on every attempt. Returns :success or
  :failure and updates the registry entry's status as it goes.``
  [job entry config sem]
  (def status (entry :status))
  (def max-attempts (inc (job :max-retries)))
  (def started-at (u/now-unix))
  (var attempt 1)
  (var outcome nil)
  (while (and (not outcome) (<= attempt max-attempts))
    (put status :state :queued)
    (ev/take sem)                       # acquire a concurrency slot (may block)
    (put status :state :running)
    (u/log/info "scheduler" "job '%s' starting (attempt %d/%d)"
                (job :name) attempt max-attempts)
    (def ts (u/filename-timestamp))
    (def log-path (u/join-path (config :logs-dir) (job :name)
                                (string/format "%s-attempt%d.log" ts attempt)))
    (def result (run/run-attempt job log-path))
    (ev/give sem true)                  # release the slot
    (def alert-fields (alerts/evaluate-attempt job result (config :alert-patterns)))
    (if (attempt-failed? result)
      (do
        (u/log/warn "scheduler" "job '%s' attempt %d/%d failed (%V)"
                    (job :name) attempt max-attempts
                    (or (result :error) (result :exit-code) "timeout"))
        (if (< attempt max-attempts)
          (do
            (def backoff (sched/backoff-seconds (job :retry-backoff) attempt))
            (u/log/info "scheduler" "job '%s' retrying in %.1fs" (job :name) backoff)
            (put status :state :retry-wait)
            (ev/sleep backoff))
          (do
            (when alert-fields (alerts/dispatch config alert-fields))
            (set outcome :failure))))
      (do
        (u/log/info "scheduler" "job '%s' succeeded (attempt %d/%d)"
                    (job :name) attempt max-attempts)
        (when alert-fields (alerts/dispatch config alert-fields))
        (set outcome :success)))
    (++ attempt))
  (put status :state :idle)
  (put status :last-run started-at)
  (put status :last-status outcome)
  (put status :run-count (inc (status :run-count)))
  (when (= outcome :failure) (put status :fail-count (inc (status :fail-count))))
  outcome)
```

The control flow:

- `max-attempts` is `:max-retries + 1` (the original try plus the
  retries). `attempt` and `outcome` are `var`s the loop updates.
- `while` runs until we have an `outcome` or we're out of attempts.
- **Acquire/release** bracket every attempt: `(ev/take sem)` takes a
  token (the job's status reads `:queued` while it waits, then `:running`
  once it has one); `(ev/give sem true)` returns the token after the
  attempt finishes. This is what makes "queued" a real, observable state.
- Each attempt logs to its own timestamped file under
  `logs/<job>/<ts>-attemptN.log`.
- On failure: log it, and if retries remain, sleep the backoff (status
  `:retry-wait`) and loop; otherwise dispatch the alert and set
  `outcome :failure`.
- On success: dispatch an alert *only if* `evaluate-attempt` flagged
  something (remember: output can match a failure pattern even on exit 0)
  and set `outcome :success`.
- `(++ attempt)` increments. After the loop, we write the final status
  counters and return the outcome.

> **Why is the slot released after *each attempt* rather than held for the
> whole run?** Because the backoff sleep between retries could be minutes
> long, and holding a precious concurrency slot idle while we *wait to
> retry* would starve other jobs. Releasing between attempts means a job
> in backoff isn't occupying a worker. The flip side — a job re-queues for
> a slot on each retry — is exactly the behavior we want.

### One fiber per job: the loop

Each job runs its own endless loop in its own fiber. The loop computes
the next run, waits for it (or a trigger), runs the job, persists state,
repeats.

```janet
(defn- job-loop
  ``Lives for as long as the job exists in the registry. Repeatedly
  figures out when the job should next run, waits for that time (or
  an out-of-band manual trigger), then runs it. Exits quietly if
  cancelled (e.g. because the job was removed by a RELOAD).``
  [name entry config sem state-box]
  (try
    (forever
      (def job (entry :spec))
      (def st (job-state state-box name))
      (def now (u/now-unix))
      (def nr (if (job :enabled) (sched/next-run (job :schedule) (st :last-run) now) nil))
      (put (entry :status) :next-run nr)
      (def delay (when nr (- nr now)))
      (wait-for-next delay (entry :trigger-chan))
      # re-fetch :spec in case a reload swapped it out
      (def job2 (entry :spec))
      (def outcome (run-job-once job2 entry config sem))
      (def prev (job-state state-box name))
      (save-job-state! state-box config name
                        {:last-run (u/now-unix)
                         :last-status outcome
                         :run-count (inc (prev :run-count))
                         :fail-count (+ (prev :fail-count) (if (= outcome :failure) 1 0))}))
    ([err] (u/log/info "control" "job '%s' loop stopped (%V)" name err))))
```

The flow per iteration:

1. Read the current spec and persisted state.
2. Compute the next-run time — `nil` if the job is disabled or its
   schedule is manual. Stash it in `:next-run` for `STATUS` to show.
3. Convert to a `delay` (or `nil`) and `wait-for-next`.
4. **Re-fetch the spec** (`job2`) after waking, because a `RELOAD` may
   have swapped in a new spec while we were asleep.
5. Run the job, then persist updated counters.

Two design points worth dwelling on:

> **No overlapping runs of the same job, by construction.** Because each
> job has exactly one loop and that loop runs the job *synchronously*
> (waits for `run-job-once` to fully finish, retries and all, before
> looping back to compute the next run), a single job can never pile up
> on itself. The `:max-concurrent` semaphore governs *different* jobs
> running in parallel; the one-fiber-per-job structure governs *the same*
> job never overlapping. Two different mechanisms for two different
> questions.

> **Why wrap the whole loop in `try`?** When `RELOAD` removes a job, we
> *cancel* its fiber (we'll see this shortly). A cancelled fiber raises
> inside whatever it was doing — here, probably an `ev/select` in
> `wait-for-next`. Without the `try`, that would print an ugly unhandled
> stack trace to the daemon's stderr. The `try` turns cancellation into a
> tidy one-line log message. We added this only after watching a reload
> spew a scary-looking (but harmless) error during testing. Catching
> *expected* cancellations is part of writing a clean long-running
> process.

### Watching the daemon's own log — and a feedback loop we caused

Beyond per-job alerting, the daemon tails *its own* log file and raises
an alert on any `ERROR`-level line — so operational problems (a crashed
control handler, say) get noticed too. This sounds trivial and contains a
genuinely instructive bug.

```janet
(defn- parse-daemon-log-line
  ``Pull the level and tag back out of a line written by u/log (see
  util.janet): "<timestamp> <LEVEL> [<tag>] <message>".``
  [line]
  (def parts (filter (fn [x] (not (empty? x))) (string/split " " line)))
  (when (>= (length parts) 3)
    {:level (string/trim (parts 1))
     :tag (string/trim (parts 2) "[]")}))
```

This parses one of our own log lines back into its level and tag. We
`filter` out empty strings first because the `%-5s` level padding can
produce a double space (e.g. `INFO  [tag]`), which `string/split " "`
would turn into an empty element. `(string/trim (parts 2) "[]")` strips
the surrounding brackets from `[scheduler]` to get `scheduler`.

```janet
(defn- log-watcher-loop
  ``Tails the daemon's own activity log and raises an alert for any
  line logged at :error level, so operational problems (not just job
  failures) get noticed too. Deliberately matches on the structured
  level field rather than doing a substring search for "ERROR" over
  the whole line -- a raw substring search would also match the word
  "ERROR" when it shows up *inside* an already-dispatched alert's
  message text (which quotes the offending line), causing every error
  to alert about itself forever. The [alert] tag is also skipped for
  the same reason.``
  [config]
  (def path (config :daemon-log))
  (var offset 0)
  (forever
    (ev/sleep 2)
    (when (os/stat path)
      (def size ((os/stat path) :size))
      (when (> size offset)
        (def f (file/open path :r))
        (when f
          (file/seek f :set offset)
          (def chunk (file/read f (- size offset)))
          (file/close f)
          (set offset size)
          (each line (string/split "\n" (or chunk ""))
            (unless (empty? line)
              (def parsed (parse-daemon-log-line line))
              (when (and parsed (= (parsed :level) "ERROR") (not= (parsed :tag) "alert"))
                (alerts/dispatch config
                                 {:job "janetd-daemon" :reason line
                                  :exit-code nil :log-path path})))))))))
```

The tailing mechanism is a classic: remember a byte `offset`, every 2
seconds check if the file grew (`os/stat` `:size`), and if so `file/seek`
to the old offset and `file/read` only the new bytes. Split into lines,
process each.

> **The feedback loop we built and had to kill.** The first version of
> this watcher did the obvious thing: `(when (string/find "ERROR" line)
> ...)`. Run it and watch the daemon melt down. Here's the cascade:
>
> 1. A real `ERROR` line appears. The watcher matches it and calls
>    `dispatch`, which (per Part 4) *writes its own line* to the log
>    quoting the offending text — a line that itself contains the word
>    "ERROR".
> 2. Two seconds later the watcher reads *that* new line, finds "ERROR"
>    in it, and dispatches again — writing yet another line containing
>    "ERROR".
> 3. Repeat forever. One real error becomes an infinite, ever-growing
>    storm of alerts.
>
> The fix is to stop doing a dumb substring search and instead **parse
> the structured level field** — match only lines whose *level column* is
> exactly `ERROR`, and additionally skip lines tagged `[alert]` (which is
> what `dispatch` emits). An alert about an error is not itself an error.
> The lesson generalizes well beyond log watching: **when a system
> observes output that it also writes to, you must make the observer able
> to recognize and ignore its own footprints**, or you get a feedback
> loop. Structured logs (a real level field, not just text) are what make
> that possible.

### The control socket: a Unix-socket command protocol

We control a running daemon through a **Unix domain socket** — a
socket that lives as a path on the filesystem, not on a network port.
The protocol is deliberately tiny: a client connects, writes one line
(`STATUS`, `TRIGGER backup`, ...), reads one reply, both sides close.

First, formatting the `STATUS` reply:

```janet
(defn- format-status [registry]
  (def lines @[])
  (each name (sort (keys registry))
    (def entry (registry name))
    (def s (entry :status))
    (array/push lines
      (string/format "%-20s state=%-11s last-run=%-20s last-status=%-8s next-run=%-20s runs=%d fails=%d"
                      name (string (s :state))
                      (if (s :last-run) (u/iso-timestamp (s :last-run)) "never")
                      (string (or (s :last-status) "-"))
                      (if (s :next-run) (u/iso-timestamp (s :next-run)) "-")
                      (s :run-count) (s :fail-count))))
  (if (empty? lines) "(no jobs configured)" (string/join lines "\n")))
```

We sort job names (`(sort (keys registry))`) for stable output, then
build one aligned line per job by reading its live `:status` table. Note
`(string (s :state))` — we stringify keywords like `:idle` *before*
handing them to `%-11s`, because (Part 3's papercut) `%s` rejects a raw
keyword. The column widths (`%-20s`, `%-11s`, ...) make the output line
up into a readable table.

Dispatching a command:

```janet
(defn- handle-command [line registry reload-fn stop-fn]
  (def parts (filter (fn [x] (not (empty? x))) (string/split " " (string/trim line))))
  (def cmd (string/ascii-upper (or (first parts) "")))
  (cond
    (= cmd "PING") "PONG"
    (= cmd "STATUS") (format-status registry)
    (= cmd "TRIGGER")
    (do
      (def name (get parts 1))
      (def entry (and name (registry name)))
      (if entry
        (do (trigger-job! entry) (string "OK triggered " name))
        (string "ERROR unknown job " (or name "(none given)"))))
    (= cmd "RELOAD") (reload-fn)
    (= cmd "STOP") (do (stop-fn) "OK stopping")
    (string "ERROR unknown command " cmd)))
```

We split the line into words, uppercase the verb, and `cond` over the
known commands, each returning the reply string. `RELOAD` and `STOP` are
passed in as functions (`reload-fn`, `stop-fn`) because they need access
to state that lives in the top-level `run` (the registry, the launcher) —
passing them as arguments keeps `handle-command` decoupled from that
machinery.

Serving it:

```janet
(defn- serve-control
  [config registry reload-fn stop-fn]
  (def sock-path (config :control-sock))
  (when (os/stat sock-path) (os/rm sock-path))
  (def server (net/listen :unix sock-path))
  (u/log/info "control" "listening on %s" sock-path)
  (ev/spawn
    (net/accept-loop server
      (fn [conn]
        (ev/spawn
          (try
            (do
              (def buf (net/read conn 4096))
              (def line (if buf (string buf) ""))
              (def reply (handle-command line registry reload-fn stop-fn))
              (net/write conn (string reply "\n")))
            ([err] (u/log/error "control" "error handling command: %V" err)))
          (try (ev/close conn) ([_] nil))))))
  server)
```

- We remove any stale socket file from a previous run (`os/rm`), then
  `net/listen` with `:unix` to create a Unix-domain listener at that
  path.
- `net/accept-loop` accepts connections forever, calling our handler with
  each `conn`. We run the *whole* accept loop inside an `ev/spawn` so it
  doesn't block `run` from finishing its setup.
- For each connection we `ev/spawn` *again*, so multiple control clients
  can be served concurrently. The handler reads the request, computes a
  reply with `handle-command`, writes it back, and closes — wrapped in
  `try` so a misbehaving client can't take down the listener.

> **Why a Unix socket and not a TCP port?** Two reasons. It needs no port
> allocation and can't be reached from the network — its access control
> is just filesystem permissions on the socket file, which is exactly
> what you want for a local control channel. And it's the same choice
> real daemons (including systemd, Docker, etc.) make for their local
> control surfaces.

### Tying it together: `run`

Finally the entry point that wires up everything and blocks forever.

```janet
(defn run
  ``Start the daemon. `home` is the state directory, `jobs-file` is
  the Janet config file to load. Blocks forever (until STOP). ...``
  [home jobs-file &opt foreground]
  (def base-config (default-config home))
  (u/ensure-dir home)
  (u/log-init (base-config :daemon-log) (not= foreground false))

  (def loaded (load-jobs-file jobs-file))
  (def config (merge base-config (loaded :config-overrides)))

  (def state-box (load-state config))
  (def sem (ev/chan (config :max-concurrent)))
  (for i 0 (config :max-concurrent) (ev/give sem true))

  (def registry (new-registry))

  (defn launch-job! [job]
    (def entry (registry-entry job state-box))
    (put registry (job :name) entry)
    (put entry :fiber
         (ev/go (fn [] (job-loop (job :name) entry config sem state-box)))))

  (each job (loaded :jobs) (launch-job! job))
  ...
```

Setup in order: build config, ensure the home dir, init logging, load and
merge the jobs file's config overrides, load persisted state. Then the
**semaphore is created and filled**: `(ev/chan N)` makes a channel of
capacity N, and the `for` loop gives it N tokens. Now `ev/take` succeeds N
times before blocking — exactly a counting semaphore.

`launch-job!` creates a registry entry and starts its `job-loop` on a
fiber with `ev/go` (like `ev/spawn` but returns the fiber, which we store
in `:fiber` so reload can cancel it). We launch every loaded job.

```janet
  (defn reload! []
    (try
      (do
        (def reloaded (load-jobs-file jobs-file))
        (def new-names (map (fn [j] (j :name)) (reloaded :jobs)))
        (def old-names (keys registry))
        # stop jobs that no longer exist
        (each name old-names
          (unless (find (fn [n] (= n name)) new-names)
            (def entry (registry name))
            (when (entry :fiber) (try (ev/cancel (entry :fiber) "reload") ([_] nil)))
            (put registry name nil)
            (u/log/info "control" "job '%s' removed on reload" name)))
        # add or update
        (each job (reloaded :jobs)
          (def existing (registry (job :name)))
          (if existing
            (do (put existing :spec job)
                (trigger-job! existing)
                (u/log/info "control" "job '%s' updated on reload" (job :name)))
            (do (launch-job! job)
                (u/log/info "control" "job '%s' added on reload" (job :name)))))
        "OK reloaded")
      ([err] (string "ERROR reload failed: " err))))

  (defn stop! []
    (ev/spawn (ev/sleep 0.2) (os/exit 0)))

  (ev/spawn (log-watcher-loop config))
  (serve-control config registry reload! stop!)

  (u/log/info "daemon" "janetd started, home=%s jobs=%d max-concurrent=%d"
              home (length (loaded :jobs)) (config :max-concurrent))

  (forever (ev/sleep 3600)))
```

`reload!` is a **live diff**, not a restart: it re-reads the jobs file,
`ev/cancel`s the fibers of jobs that vanished (that's the cancellation the
`job-loop`'s `try` quietly absorbs), swaps the spec into jobs that still
exist (and triggers them so a changed schedule re-computes immediately),
and launches brand-new jobs. State for surviving jobs is untouched.

`stop!` sleeps briefly (so the `OK stopping` reply makes it back to the
client) and then exits the process.

The last three expressions start the log watcher, start the control
server, log a startup banner, and then **park the main fiber forever**
with `(forever (ev/sleep 3600))`. Everything real happens in the spawned
fibers; the main fiber just needs to not exit, or the event loop (and the
whole daemon) would stop.

> **Why no signal handlers?** You'd expect a daemon to catch SIGTERM for
> graceful shutdown. We deliberately don't, and the docstring says why:
> on Janet 1.38.0, running arbitrary Janet code from inside an
> `os/sigaction` handler while the event loop is parked in `ev/sleep`
> reliably segfaulted in our testing. Rather than ship something that
> crashes on shutdown, we make the control socket's `STOP` the supported
> graceful path; a raw `SIGTERM`/`SIGKILL` still terminates the process,
> it just skips the niceties. **Knowing a primitive's sharp edges — and
> routing around them honestly — is part of the job.** Don't paper over a
> segfault with a handler that mostly works.

### Checkpoint — run the whole daemon

Before the CLI, let's confirm the engine works. Create a small jobs file
at the project root, `try-jobs.janet`:

```janet
(def jobs
  [{:name "heartbeat" :command ["echo" "tick"] :schedule [:every 2]}
   {:name "flaky" :command ["sh" "-c" "exit 1"] :schedule [:manual]
    :max-retries 2 :retry-backoff 1}])
(def config {:max-concurrent 2})
```

And a tiny launcher, `try-daemon.janet`:

```janet
(import ./src/daemon :as d)
(d/run "/tmp/janetd-tut/home" "./try-jobs.janet")
```

Run it in the background of one shell, poke it from the same shell, then
stop it (all in one go so the background process survives):

```sh
$ janet try-daemon.janet > /tmp/janetd-tut/out.log 2>&1 &
$ sleep 3
$ # we don't have the CLI yet, so talk to the socket with a one-liner:
$ janet -e '(import ./src/client :as c) \
    (print (c/send-command "/tmp/janetd-tut/home/control.sock" "STATUS"))'
flaky      state=idle  last-run=never  ... runs=0 fails=0
heartbeat  state=idle  last-run=2026-... last-status=success ... runs=1 fails=0
$ janet -e '(import ./src/client :as c) \
    (print (c/send-command "/tmp/janetd-tut/home/control.sock" "TRIGGER flaky"))'
OK triggered flaky
$ sleep 4   # let flaky exhaust its 2 retries
$ janet -e '(import ./src/client :as c) \
    (print (c/send-command "/tmp/janetd-tut/home/control.sock" "STATUS"))'
flaky      state=idle ... last-status=failure ... runs=1 fails=1
heartbeat  ...
$ cat /tmp/janetd-tut/home/alerts.log
2026-... job=flaky reason=exited with code 1 exit-code=1 log=.../flaky/...-attempt3.log
$ janet -e '(import ./src/client :as c) \
    (c/send-command "/tmp/janetd-tut/home/control.sock" "STOP")'
```

You should see `heartbeat` ticking every ~2 seconds (its `run-count`
climbs), `flaky` going to `failure` with one fail recorded after its
retries, an entry in `alerts.log`, and a clean stop. If you `cat
/tmp/janetd-tut/home/daemon.log` you'll see the whole story with retry
backoffs. The engine works.

> **A sandbox note:** background processes started with `&` only live as
> long as the shell session that started them. Keep the "start, poke,
> stop" sequence in a single script or a single shell so the daemon is
> still alive when you query it.

---

## Part 6 — `client.janet` and the `janetd` CLI

Two small files turn the engine into a usable command-line tool.

### The client: connecting to a Unix socket

```janet
### client.janet
### Talks to a running daemon's control socket. One command per
### connection, matching the protocol in daemon.janet's serve-control.

(defn send-command
  ``Connect to the control socket at `sock-path`, send `line`, return
  the daemon's text response (without trailing newline). Raises an
  error (with a friendly message) if the daemon isn't reachable.``
  [sock-path line]
  (def conn
    (try (net/connect :unix sock-path)
      ([_] (error (string/format
                    "could not connect to %s -- is janetd running?"
                    sock-path)))))
  (net/write conn (string line "\n"))
  (def buf (net/read conn :all))
  (ev/close conn)
  (string/trimr (if buf (string buf) "")))
```

The mirror image of `serve-control`: `net/connect` with `:unix` opens
the socket (we catch the failure and rewrite it into a friendly "is
janetd running?" message), write the command line, then `net/read` with
`:all` to read the *entire* response until the server closes its end.
`string/trimr` removes the trailing newline. That's the whole client —
18 lines, and the only client code anyone needs to script against the
daemon.

### The CLI: shebang, args, and a flag parser

The `janetd` file is the user-facing program. It starts with a shebang so
it can be run directly:

```janet
#!/usr/bin/env janet
### janetd - a small systemd-substitute daemon ...

(import ./src/daemon :as daemon)
(import ./src/client :as client)
(import ./src/util :as u)
```

> **The shebang** `#!/usr/bin/env janet` lets you `chmod +x janetd` and
> run `./janetd ...` directly — the OS invokes `janet` on the file.
> Conveniently, `#!` is also a comment to Janet (it starts with `#`), so
> the same file is both a valid script and a valid executable.

Default locations, from environment variables with fallbacks:

```janet
(defn- default-home []
  (or (os/getenv "JANETD_HOME")
      (string (or (os/getenv "HOME") "/tmp") "/.janetd")))

(defn- default-jobs-file [home]
  (or (os/getenv "JANETD_JOBS") (string home "/jobs.janet")))
```

`os/getenv` reads an environment variable (or `nil`). The nested `or`s
give us "use `$JANETD_HOME`, else `$HOME/.janetd`, else `/tmp/.janetd`".

A minimal flag parser — enough for our needs, and a good exercise in
`while` with an index:

```janet
(defn- parse-flags
  ``Very small flag parser: returns [positional-args flags-table].
  Flags look like --home VALUE or --background (boolean, no value).``
  [args boolean-flags]
  (def positional @[])
  (def flags @{})
  (var i 0)
  (while (< i (length args))
    (def a (args i))
    (if (string/has-prefix? "--" a)
      (do
        (def key (keyword (string/slice a 2)))
        (if (find (fn [b] (= b key)) boolean-flags)
          (do (put flags key true) (++ i))
          (do (put flags key (get args (+ i 1))) (+= i 2))))
      (do (array/push positional a) (++ i))))
  [positional flags])
```

It walks `args` by index. A token starting with `--` becomes a flag:
`(string/slice a 2)` drops the dashes, `keyword` turns the name into a
keyword. Boolean flags (listed in `boolean-flags`, like `:background`)
consume no value and advance by 1; value flags grab the next token and
advance by 2. Everything else is a positional argument. It returns both
as a tuple, which callers **destructure**: `(def [pos flags]
(parse-flags ...))`.

### The subcommand handlers

```janet
(defn- cmd-start [rest]
  (def [_ flags] (parse-flags rest [:background]))
  (def home (or (flags :home) (default-home)))
  (def jobs-file (or (flags :jobs) (default-jobs-file home)))
  (unless (os/stat jobs-file)
    (eprint "error: jobs file not found: " jobs-file)
    (os/exit 1))
  (if (flags :background)
    (do
      (u/ensure-dir home)
      (def out (file/open (string home "/start.log") :a))
      (os/spawn ["setsid" (dyn :executable "janet") (dyn :current-file) "start"
                 "--home" home "--jobs" jobs-file]
                :ped (merge (os/environ) {:out out :err out}))
      (print "janetd started in background, home=" home)
      (print "logs: " home "/daemon.log"))
    (daemon/run home jobs-file true)))
```

`start` either runs the daemon in the foreground (`daemon/run ...`,
blocking) or, with `--background`, **re-launches itself detached**. The
detach line has two details we earned the hard way:

- `setsid` runs the child in a new session, divorcing it from the
  controlling terminal so it survives your shell closing.
- `(dyn :executable "janet")` and `(dyn :current-file)` are how the
  process finds *itself*: `:executable` is the path to the `janet` binary
  and `:current-file` is this script's path, so we spawn
  `janet /path/to/janetd start --home ... --jobs ...`.
- The spawn flags are **`:ped`** — `p` (PATH), `e` (env table), and
  crucially **`d` (detached)**. That `d` is the Part 4 GC trap again: a
  non-detached child would be killed when this short-lived launcher
  process exits and gets garbage-collected. `d` cuts that tie so the
  daemon keeps running.

```janet
(defn- cmd-control [verb rest]
  (def [pos flags] (parse-flags rest []))
  (def home (or (flags :home) (default-home)))
  (def sock (sock-path-for home))
  (def line
    (case verb
      "status" "STATUS"
      "reload" "RELOAD"
      "stop" "STOP"
      "trigger" (do
                  (unless (first pos)
                    (eprint "error: 'trigger' needs a job name")
                    (os/exit 1))
                  (string "TRIGGER " (first pos)))))
  (try
    (print (client/send-command sock line))
    ([err] (eprint "error: " err) (os/exit 1))))
```

`status`, `reload`, `stop`, and `trigger` all reduce to "send one line to
the socket and print the reply", so they share this handler. `case` maps
the verb to the protocol command; `trigger` additionally folds in the job
name. `eprint` writes to **stderr** (versus `print` to stdout), which is
the right stream for error messages.

```janet
(defn- cmd-validate [rest]
  (def path (first rest))
  (unless path
    (eprint "error: 'validate' needs a path to a jobs file")
    (os/exit 1))
  (try
    (do
      (def loaded (daemon/load-jobs-file path))
      (print (string/format "OK: %d job(s) defined:" (length (loaded :jobs))))
      (each j (loaded :jobs)
        (print (string/format "  - %s  schedule=%q  command=%s"
                               (j :name) (j :schedule) (string/join (j :command) " ")))))
    ([err] (eprint "INVALID: " err) (os/exit 1))))
```

`validate` reuses `load-jobs-file` (which validates as it loads) and
prints a summary — a fast "is my config sane?" check that never starts a
daemon. Note `%q` for the schedule tuple (Part 2's lesson: `%q` prints
`(:every 2)`, while `%s`/`%V` would show a tuple pointer for a composite
value — actually `%V` prints it fine too, but `%q` gives the re-readable
form we want here).

### `main` and arg dispatch

```janet
(defn main [&]
  (def args (drop 1 (dyn :args)))
  (def cmd (first args))
  (def rest (drop 1 args))
  (cond
    (nil? cmd) (do (print-usage) (os/exit 1))
    (= cmd "start") (cmd-start rest)
    (or (= cmd "status") (= cmd "reload") (= cmd "stop") (= cmd "trigger"))
    (cmd-control cmd rest)
    (= cmd "validate") (cmd-validate rest)
    (or (= cmd "-h") (= cmd "--help") (= cmd "help")) (print-usage)
    (do (eprint "unknown command: " cmd) (print-usage) (os/exit 1))))
```

When you run a Janet *script* that defines a function named `main`, Janet
calls it for you. The `[&]` parameter list means "ignore any arguments";
we instead read `(dyn :args)`, the full argv array (element 0 is the
script name, hence `(drop 1 ...)`). Then a `cond` dispatches on the
subcommand. Clean and flat.

### Checkpoint — the real CLI

```sh
$ chmod +x janetd
$ ./janetd validate examples/jobs.janet      # we'll write this file in Part 7
$ JANETD_HOME=/tmp/janetd-tut/home2 JANETD_JOBS=./try-jobs.janet ./janetd start &
$ sleep 2
$ JANETD_HOME=/tmp/janetd-tut/home2 ./janetd status
$ JANETD_HOME=/tmp/janetd-tut/home2 ./janetd trigger flaky
$ JANETD_HOME=/tmp/janetd-tut/home2 ./janetd stop
```

You now have a working `janetd` binary with `start`/`status`/`trigger`/
`reload`/`stop`/`validate`.

---

## Part 7 — an example config, and packaging it up

### The example jobs file

Create `examples/jobs.janet` as both a working starting point and living
documentation of every option. Because it's plain Janet, it can use
arithmetic and comments freely:

```janet
# examples/jobs.janet -- copy to ~/.janetd/jobs.janet and edit.

(def jobs
  [{:name "heartbeat"
    :command ["echo" "still alive"]
    :schedule [:every (* 5 60)]}          # every 5 minutes

   {:name "nightly-backup"
    :command ["sh" "-c" "pg_dump mydb | gzip > /backups/mydb.sql.gz"]
    :schedule [:daily "02:30"]
    :max-retries 3
    :retry-backoff 60                      # 60s, 120s, 240s between tries
    :timeout 3600}                         # kill if it runs over an hour

   {:name "hourly-report"
    :command ["./generate-report.sh"]
    :cwd "/srv/reports"
    :env {"REPORT_FORMAT" "pdf"}
    :schedule [:hourly 0]}

   {:name "deploy-site"                     # trigger-only, e.g. from CI
    :command ["./deploy.sh"]
    :cwd "/srv/site"
    :schedule [:manual]
    :max-retries 1}

   {:name "ingest-pipeline"
    :command ["./ingest.sh"]
    :schedule [:every (* 15 60)]
    :alert-patterns ["error" "exception" "row count mismatch"]}

   {:name "experimental-job"               # present but off
    :command ["./experiment.sh"]
    :schedule [:every 60]
    :enabled false}])

(def config
  {:max-concurrent 4
   :alert-command ["sh" "-c"
     "curl -s -X POST $SLACK_WEBHOOK_URL -d \"{\\\"text\\\":\\\"janetd: $JANETD_job -- $JANETD_reason\\\"}\""]})
```

Validate it (the command won't run any jobs, just parse and check):

```sh
$ ./janetd validate examples/jobs.janet
OK: 6 job(s) defined:
  - heartbeat  schedule=(:every 300)  command=echo still alive
  - nightly-backup  schedule=(:daily "02:30")  command=sh -c pg_dump mydb | gzip > /backups/mydb.sql.gz
  ...
```

This is the moment the whole design pays off: every feature — schedules,
retries, timeouts, cwd, env, per-job alert patterns, enable/disable,
concurrency, the alert hook — is expressible as plain data in a file
you can read top to bottom.

### The module system, summarized

You've now seen Janet's module model in full:

- A file is a module. `(import ./util :as u)` loads a sibling by relative
  path and prefixes its exports as `u/...`.
- `defn`/`def`/`var` create **exported** bindings; the `-` variants
  (`defn-`, `var-`) create **private** ones.
- Imports resolve relative to the *importing file's* location, which is
  why sibling modules in `src/` import each other as `./name` while a
  REPL at the project root reaches them as `./src/name`.
- A script defining `main` gets it called automatically with the process
  args available via `(dyn :args)`.

There is no build step, no manifest, no package install for any of this —
it's all the standard library and the file system.

### Run it for real

```sh
mkdir -p ~/.janetd
cp examples/jobs.janet ~/.janetd/jobs.janet
$EDITOR ~/.janetd/jobs.janet          # make the jobs real for your machine

./janetd validate ~/.janetd/jobs.janet
./janetd start --background            # detaches; logs to ~/.janetd/daemon.log
./janetd status
./janetd trigger deploy-site
./janetd reload                        # after editing jobs.janet
./janetd stop
```

On a real host you'd hand `./janetd start` (foreground) to whatever
supervises long-running processes and wire `./janetd stop` into its
shutdown hook.

---

## Where to go next

You've built a real daemon and met most of Janet along the way:
s-expressions and the core data types; `def`/`var`/`fn`/`defn` with
`&opt`/`&` and destructuring; control flow (`if`/`when`/`unless`/`cond`/
`case`/`while`/`forever`/`each`/`seq`); the splat operator `;`; error
handling with `error`/`try`/`break`; the `ev` concurrency model (fibers,
the event loop, channels, `ev/select`, `ev/spawn`/`ev/go`/`ev/cancel`);
processes (`os/spawn`, `os/proc-wait`, `os/proc-kill`, flags, env,
redirection); Unix sockets (`net/listen`/`net/connect`/`net/accept-loop`);
the filesystem and JDN persistence; and the module system.

If you want to keep going, here are extensions in rough order of
difficulty — each reinforces something you learned:

1. **A `LOGS <job>` control command** that returns the path (or tail) of
   a job's most recent attempt log. (Practice: `os/dir`, sorting,
   extending `handle-command`.)
2. **Log retention** — after each run, delete all but the newest N attempt
   logs for a job. (Practice: filesystem listing, `sort`, `slice`.)
3. **A `:weekly [:mon "09:00"]` schedule kind.** Add a branch to
   `schedule/validate` and `schedule/next-run` using `os/date`'s
   `:week-day`. (Practice: the schedule abstraction you built is designed
   for exactly this — you should be able to add it without touching any
   other file.)
4. **Per-job concurrency or a global max-runs-per-minute rate limit.**
   (Practice: more channel-as-semaphore patterns.)
5. **A real test file.** Janet has no need for an external framework — a
   script that imports each module, asserts with `assert`, and exits
   non-zero on failure is a perfectly good test suite. Codify the
   checkpoints from this tutorial.
6. **Job dependencies** (`:after ["other-job"]`): only start a job once
   its prerequisites have succeeded. (Practice: this one is genuinely
   hard — it needs cross-job coordination through shared channels or a
   completion-broadcast — and will teach you the most about the
   concurrency model.)

A closing thought on method. The single most valuable habit this project
can teach isn't a Janet feature — it's that **every one of the bugs called
out in these asides was found by actually running small pieces and
checking the output against what we expected.** The off-by-one in dates,
the struct-vs-table mutability error, the `%s`-on-a-number crash, the
GC-killed child, the alert feedback loop, the absolute-path directory bug:
none were caught by reading the code, all were caught by running it. Build
in small pieces, run each piece, verify the output, and let the surprises
teach you. That's the whole craft.
