# MediaRemote Adapter

Source: https://github.com/ungive/mediaremote-adapter
Pinned commit: 73f14ab1568371e6e3c44063f21c34c5e2712c4d
License: BSD 3-Clause (see LICENSE).

Captur builds the get/metadata portion as CapturMediaRemoteAdapter.framework,
loads it only from Apple's /usr/bin/perl, and embeds the license in its app.
Captur patches `src/adapter/get.m` to exit unsuccessfully on a query timeout,
so a failed query is distinguishable from an empty session. Other upstream source
is unchanged. Captur's script and guarded pause/play entry point
live under Sources/Resources and Sources/Modules/Audio/MediaRemoteHelper.
Only get and guarded pause/play are exposed through Captur's script. Upstream's
fake-player test, stream, and unrestricted send entry points are not built.
