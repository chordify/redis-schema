# CHANGELOG

## v0.2.1

- Bump hedis lower bound to 0.16.3 and remove orphan instance in favour of upstream one (see [#13](https://github.com/chordify/redis-schema/pull/13)).

## v0.2

- Support GHC 9.8-9.12. Bump `hedis` to 0.16 (see [#11](https://github.com/chordify/redis-schema/pull/11)).
- Throw errors on silent discarding of errors from ByteString decoding (see [#10](https://github.com/chordify/redis-schema/pull/10)).

**Breaking changes** (since `hedis-0.16`).

1. Drop support of GHCs older than 9.6.
2. Non-empty lists used elsewhere in the code.

**Migration guide**

1. In case of compilation errors replace `[a]` with `NonEmpty a`, e.g. 
  - `[v]` with `pure v` 
  - or `(v :| [])` 
  - or `NE.singleton v` (`import qualified Data.List.NonEmpty as NE`).

## v0.1

First public version of `redis-schema`.
