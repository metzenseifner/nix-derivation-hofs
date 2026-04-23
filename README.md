# Composition

How could I compose `withTime`, `withHelps`, `withEnv`, and `withExpansion` into a new function called `withExtras`?


The challenge is that these four functions have different signatures:

┌───────────────┬──────────────────────────────────────────────────┐
│   Function    │                    Signature                     │
├───────────────┼──────────────────────────────────────────────────┤
│ withTime      │ { pkgs, pkg } -> Package                         │
├───────────────┼──────────────────────────────────────────────────┤
│ withHelps      │ String -> Package -> Package                     │
├───────────────┼──────────────────────────────────────────────────┤
│ withEnv       │ { pkgs, pkg, filter?, descriptions? } -> Package │
├───────────────┼──────────────────────────────────────────────────┤
│ withExpansion │ { pkgs, pkg } -> Package                         │
└───────────────┴──────────────────────────────────────────────────┘

`withHelps` is the odd one out — it's curried and only attaches metadata (no wrapping). The other three create new wrapper derivations via `writeShellScriptBin`.

## Strategies 

Here are a few composition strategies:

1. Simple pipeline — apply all four in sequence

```
withExtras =
  { pkgs, pkg, doc ? null, filter ? null, descriptions ? {} }:
  let
    p1 = withTime { inherit pkgs; pkg = pkg; };
    p2 = withEnv { inherit pkgs filter descriptions; pkg = p1; };
    p3 = withExpansion { inherit pkgs; pkg = p2; };
  in
  if doc != null then withHelps doc p3 else p3;
```

This is straightforward but creates 3 nested wrapper scripts. Execution order (outermost first): `expansion → env → time → original`.

2. Kleisli-style composition with a combinator

# compose : [Package -> Package] -> Package -> Package
`compose = builtins.foldl' (acc: f: pkg: f (acc pkg)) (pkg: pkg);`

```
withExtras =
  { pkgs, doc ? null, filter ? null, descriptions ? {} }:
  let
    pipeline = [
      (pkg: withTime { inherit pkgs; inherit pkg; })
      (pkg: withEnv { inherit pkgs pkg filter descriptions; })
      (pkg: withExpansion { inherit pkgs; inherit pkg; })
    ] ++ pkgs.lib.optional (doc != null) (withHelps doc);
  in
  compose pipeline;
```

This returns a function `Package -> Package`, so usage is:

```
hello-extras = withExtras { inherit pkgs; doc = "Hello!"; } pkgs.hello;
```

The advantage is it's data-driven — you can conditionally add/remove steps from the pipeline list.

3. Attrset-style matching your existing conventions

```
withExtras =
  { pkgs, pkg, doc ? null, filter ? null, descriptions ? {} }:
  builtins.foldl'
    (p: f: f p)
    pkg
    ([
      (p: withTime { inherit pkgs; pkg = p; })
      (p: withExpansion { inherit pkgs; pkg = p; })
      (p: withEnv { inherit pkgs; pkg = p; inherit filter descriptions; })
    ] ++ pkgs.lib.optional (doc != null) (withHelps doc));
```

This matches the `{ pkgs, pkg, ... }` pattern of your other combinators and reads naturally:

```
hello-extras = withExtras {
  inherit pkgs;
  pkg = pkgs.hello;
  doc = "Documented, timed, expanded, env-printed hello.";
};
```

Option 3 fits the existing API style (attrset args, pkg
in / Package out), the `foldl'` makes the pipeline explicit and reorderable,
and optional params like doc/filter/descriptions only activate when provided.
