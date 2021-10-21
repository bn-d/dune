These tests is a regression test for the detection of dynamic cycles.

In all tests, we have a cycle that only becomes apparent after we
start running things. In the past, the error was only reported during
the second run of dune.

  $ dune build @package-cycle
  Error: Dependency cycle between:
     alias a/.a-files
  -> alias b/.b-files
  -> alias a/.a-files
  -> required by alias package-cycle in dune:1
  [1]

  $ dune build @simple-repro-case
  Error: Dependency cycle between:
     _build/default/y
  -> _build/default/x
  -> _build/default/y
  -> required by alias simple-repro-case in dune:5
  [1]

  $ dune build x1
  Error: Dependency cycle between:
     _build/default/x2
  -> _build/default/x3
  -> _build/default/x2
  -> required by _build/default/x1
  [1]

  $ dune build @complex-repro-case
  Error: Dependency cycle between:
     _build/default/cd3
  -> _build/default/cd2
  -> _build/default/cd1
  -> _build/default/cd4
  -> _build/default/cd3
  -> required by alias complex-repro-case in dune:22
  [1]

In some cases the dependencies are indirect (#666, #2818).
They can make the error message worse.

For the simple case, dependencies are enough to detect a cycle with a nice
error message.

  $ echo 'val x : unit' > indirect/c.mli
  $ dune build @indirect-deps
  Error: dependency cycle between modules in _build/default/indirect:
     A
  -> C
  -> A
  -> required by _build/default/indirect/a.exe
  -> required by alias indirect/indirect-deps in indirect/dune:6
  [1]

But when the cycle is due to the cmi files themselves, the message becomes
cryptic and can involve unrelated files:

  $ echo 'val xx : B.t' >> indirect/c.mli
  $ dune build @indirect-deps
  Error: Dependency cycle between:
     _build/default/indirect/.a.eobjs/a.impl.all-deps
  -> _build/default/indirect/.a.eobjs/b.impl.all-deps
  -> _build/default/indirect/.a.eobjs/c.intf.all-deps
  -> _build/default/indirect/.a.eobjs/a.impl.all-deps
  -> required by _build/default/indirect/a.exe
  -> required by alias indirect/indirect-deps in indirect/dune:6
  [1]

This is a reproduction case from issue #4345
  $ DIR="gh4345"
  $ mkdir $DIR && cd $DIR
  $ echo "(lang dune 2.8)" > dune-project
  $ mkdir lib
  $ touch lib.opam file lib/lib.ml
  $ cat >lib/dune <<EOF
  > (library (name lib) (public_name lib))
  > (copy_files (files ../file))
  > EOF
  $ dune build --root .
  Internal error, please report upstream including the contents of _build/log.
  Description:
    ("internal dependency cycle",
    { frames =
        [ ("eval-pred",
          { dir = In_build_dir "default"
          ; predicate = { id = Glob "file" }
          ; only_generated_files = false
          })
        ; ("dir-contents-get0", ("default", "default/lib"))
        ; ("stanzas-to-entries", "default")
        ; ("<unnamed>", ())
        ; ("<unnamed>", ())
        ; ("<unnamed>", ())
        ; ("<unnamed>", ())
        ; ("load-dir", In_build_dir "default")
        ]
    })
  Raised at Memo.Exec.exec_dep_node.(fun) in file "src/memo/memo.ml", line
    1337, characters 31-64
  Called from Fiber.Execution_context.apply in file "src/fiber/fiber.ml", line
    182, characters 9-14
  Re-raised at Stdune__Exn.raise_with_backtrace in file
    "otherlibs/stdune-unstable/exn.ml", line 36, characters 27-56
  Called from Fiber.Execution_context.run_jobs in file "src/fiber/fiber.ml",
    line 204, characters 8-13
  Re-raised at Stdune__Exn.raise_with_backtrace in file
    "otherlibs/stdune-unstable/exn.ml", line 36, characters 27-56
  Called from Fiber.Execution_context.run_jobs in file "src/fiber/fiber.ml",
    line 204, characters 8-13
  Re-raised at Stdune__Exn.raise_with_backtrace in file
    "otherlibs/stdune-unstable/exn.ml", line 36, characters 27-56
  Called from Fiber.Execution_context.run_jobs in file "src/fiber/fiber.ml",
    line 204, characters 8-13
  Re-raised at Stdune__Exn.raise_with_backtrace in file
    "otherlibs/stdune-unstable/exn.ml", line 36, characters 27-56
  Called from Fiber.Execution_context.run_jobs in file "src/fiber/fiber.ml",
    line 204, characters 8-13
  Re-raised at Stdune__Exn.raise_with_backtrace in file
    "otherlibs/stdune-unstable/exn.ml", line 36, characters 27-56
  Called from Fiber.Execution_context.run_jobs in file "src/fiber/fiber.ml",
    line 204, characters 8-13
  Re-raised at Stdune__Exn.raise_with_backtrace in file
    "otherlibs/stdune-unstable/exn.ml", line 36, characters 27-56
  Called from Fiber.Execution_context.run_jobs in file "src/fiber/fiber.ml",
    line 204, characters 8-13
  Re-raised at Stdune__Exn.raise_with_backtrace in file
    "otherlibs/stdune-unstable/exn.ml", line 36, characters 27-56
  Called from Fiber.Execution_context.run_jobs in file "src/fiber/fiber.ml",
    line 204, characters 8-13
  Re-raised at Stdune__Exn.raise_with_backtrace in file
    "otherlibs/stdune-unstable/exn.ml", line 36, characters 27-56
  Called from Fiber.Execution_context.run_jobs in file "src/fiber/fiber.ml",
    line 204, characters 8-13
  Re-raised at Stdune__Exn.raise_with_backtrace in file
    "otherlibs/stdune-unstable/exn.ml", line 36, characters 27-56
  Called from Fiber.Execution_context.run_jobs in file "src/fiber/fiber.ml",
    line 204, characters 8-13
  Re-raised at Stdune__Exn.raise_with_backtrace in file
    "otherlibs/stdune-unstable/exn.ml", line 36, characters 27-56
  Called from Fiber.Execution_context.run_jobs in file "src/fiber/fiber.ml",
    line 204, characters 8-13
  -> required by ("build-alias", { dir = "default"; name = "default" })
  
  I must not crash.  Uncertainty is the mind-killer. Exceptions are the
  little-death that brings total obliteration.  I will fully express my cases. 
  Execution will pass over me and through me.  And when it has gone past, I
  will unwind the stack along its path.  Where the cases are handled there will
  be nothing.  Only I will remain.
  [1]
  $ cd ..
