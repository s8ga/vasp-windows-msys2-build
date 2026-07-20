# Contributing

This is a small deliverable repo. Keep changes focused on the Windows MSYS2
portable build path.

## Do

- Keep docs in **English**.
- Test changes with `bash build_pipeline.sh` against a licensed tarball kept
  outside the repo.
- Preserve the `vasp_cmake` git submodule (do not vendor a full copy).

## Do not

- Commit VASP source, tarballs, `POTCAR` / `potpaw*`, portable ZIPs, or
  `build_work/` trees (see `.gitignore`).
- Push to remotes unless the maintainer explicitly asks (default: local only).
- Mix large research evidence dumps into this repository.
