# Image, PDF and operation tools

Open **Images** or **PDF** from the shelf action grid. Selected files are loaded into the tools window; with no selection, the shelf files are loaded. Add or remove sources there, and use the arrows to arrange their order. Generated results return to the shelf. Originals are not modified by media tools.

## Image conversion and resizing

The format menus come from this Mac's ImageIO decoders and encoders. Supported inputs and outputs differ by macOS version. A format being readable does not imply it is writable. There is no claim of supporting every image format ever created. The window lists the actual formats available on the current Mac.

Resize to a bounding width/height or a percentage, retaining the aspect ratio. Enlargement is off by default. EXIF orientation is applied to the pixels. Color profiles are retained while identifying metadata is removed by default. Keeping metadata is explicit because it may include location information.

Transparency loss, bit-depth reduction, and flattening an animated or multi-page input to its first frame require explicit options. Conversion renders RAW images to pixels and does not retain editable camera sensor data. Lossy formats and resizing change image data. Exceptionally large decoded images are refused with a clear message rather than exhausting memory or silently reducing their dimensions.

## Background removal

The quality engine uses the full BiRefNet Core ML conversion, not the smaller Lite model. It predicts a soft mask at 1024 by 1024 and applies it at the original image dimensions. Original pixel dimensions do not mean that every hair or transparent edge can be recovered perfectly. Review the output at full size. This is not a claim that BiRefNet is universally the best model or that the conversion is the separate HR-matting model.

The quality model is an optional 496 MB download. It is not included in DropShelf.app or DropShelf.dmg. Install it by pressing **Download Model** in Preferences or under **Images > Remove background**. The download is pinned by revision, expected byte count and SHA-256 for each file. It requires macOS 15 or later. Cancelled or failed installation removes incomplete downloads.

Choosing Quality or starting background removal never downloads or repairs a missing model. If the verified model is ready, Quality processing loads it locally without another prompt. Use **Remove downloaded model** in Preferences or Image Tools to delete the downloaded package and compiled cache. Apple Vision requires macOS 14 or later, runs locally and needs no model download. Images are processed locally and are not uploaded. Downloads retrieve model files only after the explicit install action; there is no cloud fallback. Model attribution and license information accompany the app.

## PDF tools

- Merge PDFs in source order while keeping PDF text and vector pages.
- Extract or reorder pages from one PDF with an ordered list such as `3, 1, 5-8`. Repeated pages are allowed.
- Create one PDF page per image in source order, applying image orientation.

Locked, encrypted, invalid or unavailable inputs produce errors. Generated PDFs are new documents; source digital signatures are not retained or validated. Interactive behavior and document-level features may differ in newly assembled PDFs. Inspect the output before sharing.

## Progress and cancellation

One operation runs at a time. File transfers report copy progress; image/PDF tools report file or page progress. ZIP compression and indivisible framework calls use indeterminate progress when the system does not expose measurable completion. Cancel stops at the next safe checkpoint; an active ZIP process is terminated. A single decode, encode or model inference may need to return before cancellation finishes.

Incomplete generated results are removed and never added to the shelf. Completed file moves, copies and Trash actions are reconciled with the shelf and reported if a batch stops partway through. Cancel is not Undo. Quitting requests cancellation and waits for active-operation cleanup before purging staging. Receiving promised files from another application remains a provider-controlled operation.

Removing the optional model runs to completion once started, so it has no Cancel button; quitting waits for removal to finish. Removal also clears abandoned model-download folders, including files left by an interrupted app session. Downloading the model remains cancellable.

Generated media uses private per-operation staging directories and the existing Recent Drops lifecycle. The existing memory-only clipboard history and its expiry rules are unchanged.
