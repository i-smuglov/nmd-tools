---
description: WoW addon Lua style aligned with Northern Sky Raid Tools patterns
alwaysApply: true
---

# Nmd — Lua & addon conventions

Use **[NorthernSkyRaidTools](https://github.com/Reloe/NorthernSkyRaidTools)** as the reference for structure and habits when adding or refactoring code. Match its spirit: clear namespaces, minimal globals, explicit initialization, and predictable event flow.

Use our naming Nmd.

## Local definition order (Lua)

`local function` bindings are **not** hoisted: a function only exists after its `local function Name()` line in the file. If `Foo` calls `Bar`, define `Bar` **above** `Foo` (same as any other `local`). Example: keep `EnsureDBDefaults` before helpers such as `IsMythic` that call it. If two locals must reference each other, use a forward declaration (`local Bar;` then assign `function Bar()` later) or reorder so the dependency chain is top-down.