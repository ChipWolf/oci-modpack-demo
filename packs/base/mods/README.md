# `base/mods/`

Drop jars here that ship in **every** derived pack (e.g. Geyser, Floodgate,
spark, BlueMap, common server-side mods).

These files become part of the shared base layer; the registry de-duplicates
them across every pack tag, and clients only download them once even if they
pull all three tech/magic/adventure tags.

This README is intentionally the only file under version control here. The
demo's build script tars the directory verbatim and ships it as a layer; if
you add a real jar, the layer digest will change but the *position* of the
layer in each pack's manifest stays stable, which preserves reuse.
