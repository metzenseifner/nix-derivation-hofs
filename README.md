# Composition

How could I compose `withTime`, `withHelps`, `withEnv`, and `withExpansion` into a new function called `withExtras`?


All four are now config-first and curried — each takes a configuration attrset
and returns an endofunctor `Package -> Package`:

┌───────────────┬────────────────────────────────────────────────────────┐
│   Function    │                       Signature                        │
├───────────────┼────────────────────────────────────────────────────────┤
│ withTime      │ { pkgs } -> Package -> Package                         │
├───────────────┼────────────────────────────────────────────────────────┤
│ withHelps     │ String -> Package -> Package                          │
├───────────────┼────────────────────────────────────────────────────────┤
│ withEnv       │ { pkgs, filter?, descriptions? } -> Package -> Package │
├───────────────┼────────────────────────────────────────────────────────┤
│ withExpansion │ { pkgs } -> Package -> Package                         │
└───────────────┴────────────────────────────────────────────────────────┘

`withHelps` only attaches metadata (no wrapping); the other three create new
wrapper derivations via `writeShellScriptBin`. Since every one is `Config ->
Package -> Package`, applying the config first yields a uniform `Package ->
Package` morphism, so they all drop straight into a composition pipeline.

## Strategies 

Here are a few composition strategies:

1. Simple pipeline — apply all four in sequence

```
withExtras =
  { pkgs, pkg, doc ? null, filter ? null, descriptions ? {} }:
  let
    p1 = withTime { inherit pkgs; } pkg;
    p2 = withEnv { inherit pkgs filter descriptions; } p1;
    p3 = withExpansion { inherit pkgs; } p2;
  in
  if doc != null then withHelps doc p3 else p3;
```

This is straightforward but creates 3 nested wrapper scripts. Execution order (outermost first): `expansion → env → time → original`.

2. Kleisli-style composition with a combinator

Because every combinator is already `Config -> (Package -> Package)`, fixing the
config gives you the `Package -> Package` morphisms directly — no `pkg: ...`
lambdas needed.

# compose : [Package -> Package] -> Package -> Package
`compose = builtins.foldl' (acc: f: pkg: f (acc pkg)) (pkg: pkg);`

```
withExtras =
  { pkgs, doc ? null, filter ? null, descriptions ? {} }:
  let
    pipeline = [
      (withTime { inherit pkgs; })
      (withEnv { inherit pkgs filter descriptions; })
      (withExpansion { inherit pkgs; })
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
      (withTime { inherit pkgs; })
      (withExpansion { inherit pkgs; })
      (withEnv { inherit pkgs filter descriptions; })
    ] ++ pkgs.lib.optional (doc != null) (withHelps doc));
```

This matches the config-first, curried convention of the other combinators and reads naturally:

```
hello-extras = withExtras {
  inherit pkgs;
  pkg = pkgs.hello;
  doc = "Documented, timed, expanded, env-printed hello.";
};
```

Option 3 fits the API style (config-first, `Package -> Package` out), the
`foldl'` makes the pipeline explicit and reorderable, and optional params like
doc/filter/descriptions only activate when provided.
