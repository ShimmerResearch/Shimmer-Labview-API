# Shimmer-Labview-API

LabVIEW support for Shimmer devices. **This repo is mid-migration**, and that shapes almost every
decision in it.

## The migration

LabVIEW support is moving onto a **new wrapper built over the core C# API** (`Shimmer-C-API`). The
old LabVIEW API is being retired and existing users have to migrate onto the wrapper.

The stated reason, from `Readme.md`: the C# API is widely used across research, industry and Shimmer's
own internal tools, so it is the most heavily developed and tested. Aligning LabVIEW to it gives
consistent behaviour and faster fixes rather than a second parallel implementation to maintain.

**The practical consequence:** this is a wrapper, not an implementation. A parsing, protocol,
calibration or timestamp fix belongs in `Shimmer-C-API` — fix it there and it reaches LabVIEW users
through the bridge. Reimplementing that logic here would recreate exactly the divergence the
migration exists to remove.

```
ShimmerLabviewC#Wrapper/   ShimmerBridge.cs, ShimmerLVWrapper.sln/.csproj — the C# bridge
ShimmerLabview/            Bin/, Examples/ — the LabVIEW side
```

The wrapper uses `packages.config`-style NuGet, so restore behaves differently from the
`PackageReference` projects elsewhere in `C:\dev\csharp\`.

## Before changing anything here

Check whether the change belongs in `Shimmer-C-API` instead. If it does, make it there; if it is
genuinely bridge-specific — marshalling, LabVIEW type mapping, the VI surface — it belongs here.
Say which you concluded and why, because the answer is not obvious from inside this repo.

Anything documenting the *old* LabVIEW API is being retired: prefer updating the wrapper's story over
extending the legacy one.

## How a C# API release reaches this repo

`.github/workflows/update-shimmerapi.yml` (DEV-1299) checks nuget.org every day. When there is a
newer stable `ShimmerAPI` than `packages.config` pins, it runs `tools/Update-ShimmerApi.ps1`. The
script:

- moves the pin, which is in three places: `packages.config`, and the reference's version and
  `HintPath` in `ShimmerLVWrapper.csproj`;
- rebuilds the wrapper;
- copies the DLLs it needs into `ShimmerLabview/Bin/`.

The workflow then proposes all of that as a pull request on `shimmerapi-<version>`. Merging the pull
request publishes a GitHub release (`release.yml`, tag `shimmerapi-v<version>`) with
`ShimmerLabview/` as a zip.

- **`Bin/` is what LabVIEW users run.** Its contents are worked out from the build, not chosen by
  hand: `ShimmerLVWrapper.dll` and every DLL its references reach, which today is 8 DLLs. What the
  .NET Framework supplies stays out.
  - Pull requests check `Bin/` with `tools/Update-ShimmerApi.ps1 -Check`.
  - Don't copy DLLs in by hand. To repair `Bin/`, run the script with `-Version` set to the pinned
    version.
- **Restore through the solution.** A `packages.config` restore of the project on its own fails,
  because it has no solution directory.
- **The script needs Windows PowerShell 5.1,** not `pwsh`, and MSBuild from Visual Studio or the
  Build Tools.
- **Opening the pull request** needs "Allow GitHub Actions to create and approve pull requests" in
  Settings > Actions > General. Without it, the workflow still pushes the branch, and the run's
  summary links the pull request to open by hand.
- **Nothing runs LabVIEW in CI.** Try the example VIs on a Shimmer3 and a Shimmer3R before merging an
  update.
