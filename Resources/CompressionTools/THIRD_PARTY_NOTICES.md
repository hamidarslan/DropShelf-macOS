# Compression tool notices

DropShelf bundles the following command-line tools for local, lossless file optimization. They do not make network requests at runtime.

- qpdf 12.4.2, licensed under Apache License 2.0.
- libjpeg-turbo 3.2.0 `jpegtran`, distributed under the licenses documented in `licenses/libjpeg-turbo-LICENSE.md`.
- Zopfli 1.0.3, licensed under Apache License 2.0 and statically linked into qpdf.
- Oxipng 10.2.1, licensed under the MIT License.

Pinned source URLs and SHA-256 checksums are recorded in `sources.json`. Full license texts are included in the `licenses` directory.

The qpdf source build removes non-license generator-attribution comments from bundled shell-completion text. Completion behavior, copyright notices and license terms are unchanged.
