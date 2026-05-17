# CDM Blizzard API Reference

This is the local maintainer reference for Blizzard API facts that affect Cooldown Manager taint safety. The raw documentation source is the vendored FrameXML corpus under `tests/api-docs/blizzard/`; the enforceable CDM policy table is `tests/api-docs/cdm_blizzard_reference.lua`.

## Source Files

- `CooldownViewerDocumentation.lua`: `C_CooldownViewer` catalog and `CooldownViewerCooldown` structure.
- `FrameAPICooldownDocumentation.lua`: `CooldownFrame` duration and style methods.
- `UnitAuraDocumentation.lua`: aura `DurationObject` source.
- `TotemDocumentation.lua`: totem `DurationObject` source.
- `CurveUtilDocumentation.lua`: C-side boolean decode helpers.
- `SimpleStatusBarAPIDocumentation.lua`: StatusBar timer duration sink.

Refresh the generated API index after replacing the vendored corpus:

```powershell
lua tools\test_taint.lua --update-index
```

## Cooldown Viewer

CDM treats `C_CooldownViewer` as catalog and mirror identity data, not as renderer policy.

- `C_CooldownViewer.GetCooldownViewerCategorySet(category, allowUnlearned)` provides cooldown IDs for a Blizzard viewer category.
- `C_CooldownViewer.GetCooldownViewerCooldownInfo(cooldownID)` provides `CooldownViewerCooldown` identity fields.
- `CooldownViewerCooldown` includes `cooldownID`, `spellID`, `overrideSpellID`, `overrideTooltipSpellID`, `linkedSpellIDs`, `selfAura`, `hasAura`, `charges`, `isKnown`, `flags`, and `category`.

CDM mirror code must sanitize Cooldown Viewer fields before comparing or storing them as identity. Secret or unusable fields become unknown.

## DurationObject Sources

Preferred CDM timing comes from `LuaDurationObject` values:

- `C_UnitAuras.GetAuraDuration(unit, auraInstanceID)` returns a `LuaDurationObject`.
- `GetTotemDuration(slot)` returns a `LuaDurationObject`.
- Blizzard Cooldown Viewer child hooks capture `Cooldown:SetCooldownFromDurationObject(duration, clearIfZero)` calls and pass the object through.

Runtime code may store a `DurationObject` for later pass-through, but must not read timing from it, convert it, or branch on secret return values from its methods.

## Cooldown Frame Sinks

Preferred cooldown frame sink:

- `Cooldown:SetCooldownFromDurationObject(durationObject, clearIfZero)`

Unsafe from tainted addon code when arguments may be secret:

- `Cooldown:SetCooldown(start, duration, modRate)`
- `Cooldown:SetCooldownFromExpirationTime(expirationTime, duration, modRate)`
- `Cooldown:SetCooldownDuration(duration, modRate)`
- `Cooldown:SetCooldownUNIX(start, duration, modRate)`

`CDMRenderers.ApplyNumericCooldown` is the only CDM facade allowed to call `SetCooldown`, and only for clean numeric item timing that was already proven non-secret.

For bars, prefer:

- `StatusBar:SetTimerDuration(durationObject, interpolation, direction)`

Numeric StatusBar values are only safe when they are ordinary Lua numbers and not derived from a secret payload.

## Secret Boolean Decode

The approved C-side path for a potentially-secret boolean is:

```lua
C_CurveUtil.EvaluateColorValueFromBoolean(secretBool, 1, 0)
```

The original boolean must not be compared, truthiness-tested, sorted, or otherwise branched on in Lua before the CurveUtil call. If CurveUtil is missing or the returned scalar is still secret/unusable, treat the value as unknown.

## Enforced Checks

`tests/cdm_blizzard_reference_test.lua` checks that:

- The local policy table points at existing vendored Blizzard docs.
- The generated API index still has the CDM-relevant `AllowedWhenUntainted` contracts.
- Raw FrameXML docs still describe `DurationObject` sources/sinks and the CurveUtil boolean decode path.
- Production CDM code does not call unsafe cooldown setters directly outside the approved numeric fallback facade.
