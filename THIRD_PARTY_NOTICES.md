# Third-party software

- [KnotsUI](https://github.com/knots-ui/knots), MIT. Copyright 2026 Knots contributors. See the pinned checkout's `LICENSE.md`.
- [libgit2](https://github.com/libgit2/libgit2), GPLv2 with linking exception. See `vendor/libgit2/COPYING`; the linking exception permits distribution of the application under another license subject to its terms. Include the library's notices and source access in distributions.
- [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono), SIL Open Font License 1.1. Embedded unmodified font; include `assets/OFL.txt`.
- [Devicon](https://github.com/devicons/devicon/tree/v2.17.0), MIT. Copyright (c) 2015 konpa. Embedded unmodified `fonts/devicon.ttf` from v2.17.0 for file-type icons; include `assets/Devicon-LICENSE.txt`. Glyphs are colored by Weaver; brand marks identify file types and do not imply endorsement.
- [Lucide](https://github.com/lucide-icons/lucide/tree/0.468.0), ISC with Feather portions under MIT. Embedded unmodified `lucide-static@0.468.0/font/lucide.ttf` for toolbar and context-menu icons; include `assets/Lucide-LICENSE.txt`.
- [Native File Dialog Extended](https://github.com/btzy/nativefiledialog-extended/tree/v1.4.1), zlib license. Pinned revision `65b2f070a0fcfee0d453a64e770a217ab0b6ff4f`; include `assets/NFD-LICENSE.txt`.
- Knots dependencies include AccessKit, Vulkan bindings/headers, TrueType, zig-objc, wgpu and Windows bindings. The release pipeline collects downloaded dependency license texts with `scripts/collect-licenses.py` and includes them in installer bundles.

Before publishing, choose Weaver's application license and publish the reproducible source/build information for libgit2. libgit2 v1.9.7 source is available at https://github.com/libgit2/libgit2/tree/v1.9.7; Weaver's bootstrap scripts document its build options, including the optional Windows version-resource guard.
