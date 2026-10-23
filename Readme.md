We are transitioning LabVIEW support to a new wrapper built on our core C# API.
The C# API is widely used across research, industry, and our internal tools, and hense highly prioritized for development and testing.
By aligning LabVIEW with this core API, we ensure more consistent behaviour, faster updates, and higher software quality across all platforms.
If you are currently using the old LabVIEW API, you will need to migrate to the new wrapper.
This update will place your application on our primary, best-supported API moving forward.
The new approach also streamlines future feature releases and bug fixes, benefiting all downstream integrations.
We appreciate your cooperation as we unify our development path and strengthen long-term support for LabVIEW users.

## Getting the wrapper

Each [release](https://github.com/ShimmerResearch/Shimmer-Labview-API/releases) has `ShimmerLabview/` as a zip, built on the ShimmerAPI version it is named for.
Unzip it and open `ShimmerLabview/Examples/ShimmerLabview.lvproj`; the VIs load the DLLs in `ShimmerLabview/Bin/`.
A clone of this repository has the same files.
The wrapper moves to each new ShimmerAPI release through a pull request, which is tested on Shimmer3 and Shimmer3R devices before it is merged.
