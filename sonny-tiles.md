# Sonny's LiDAR DTM Tiles

Elevation comes from [Sonny's LiDAR Digital Terrain Models](https://sonny.4lima.de/)
(`graph.elevation.provider: sonny`), not from SRTM. The 1" set is derived from
national airborne laserscan surveys — roughly 20 × 30 m horizontal resolution
with ~1 m vertical accuracy, which is a large improvement over SRTM in the
mountains, where most of our hiking and MTB routing happens.

## Where the tiles come from

Sonny publishes them on a Google Drive folder linked from
<https://sonny.4lima.de/>, and there is no direct-download URL, so
**GraphHopper cannot fetch them itself** — its base URL for this provider is a
placeholder that will never resolve. The tiles are downloaded and unpacked by
hand, once; they only need refreshing when Sonny publishes a new version.

- Source page: <https://sonny.4lima.de/>
- Coverage map: <https://sonny.4lima.de/map.png>
- Europe-wide **DTM 1" (without Greenland): ~4.8 GB** as downloaded. Unpacked it
  is several times that: every 1° tile is 3601 × 3601 int16 ≈ 25 MB, and
  GraphHopper writes its own decoded `dem*` copy of each tile it touches next to
  them. Budget ~50 GB of disk for the cache directory.

Our tiles are the SRTM-filled variant, so the cross-border areas have no holes.

## Where they go

`graph.elevation.cache_dir: ./sonny-dem/` — i.e. `/opt/graphhopper/sonny-dem/`,
shared by both instances and outside `graph-cache.{a,b}`, which `gh-update.sh`
deletes wholesale on every rebuild.

Files go **directly in that directory, unzipped, no subdirectories**, named
`N49E019.hgt`, `N48E017.hgt`, … Case matters on Linux: uppercase `N`/`S`/`E`/`W`
and the `.hgt` extension exactly as shipped. The directory must be **writable**
by the `freemap` user — GraphHopper stores its decoded `dem*` tile cache there
alongside the `.hgt` files. That cache roughly doubles the size of the
directory, and `graph.elevation.clear: false` in the configs keeps it between
imports; GraphHopper 11 would otherwise delete it on exit and re-decode every
tile on the next run. Only the `dem*` files are ever removed by that mechanism —
`GHDirectory.clear()` touches nothing it did not create, so the `.hgt` tiles are
never at risk.

On fm5 the bulk data lives on `/fm/data4` and is symlinked into
`/opt/graphhopper`, the same as `graph-cache.{a,b}` and the old `srtmprovider`:

```bash
sudo install -d -o freemap -g freemap -m 2775 /fm/data4/graphhopper-data/sonny-dem
sudo -u freemap ln -s /fm/data4/graphhopper-data/sonny-dem /opt/graphhopper/sonny-dem
ls /opt/graphhopper/sonny-dem/ | head    # N43E005.hgt, N43E006.hgt, ...
```

## Downloading

The tiles sit in one flat public Drive folder, "DTM Europe 1asec v25 by Sonny",
one zip per 1° tile (`N49E019.zip` → `N49E019.hgt`):

| | |
| --- | --- |
| folder id | `0BxphPoRgwhnoWkRoTFhMbTM3RDA` |
| resource key | `0-wRe5bWl96pwvQ9tAfI9cQg` |
| short link | <https://bit.ly/dtm-europe-1s-v2> |

Scraping the folder page only ever yields the first ~50 entries, and `gdown`
caps folder downloads at 50 files, so use `rclone` with a Drive remote — the
old-style share needs both the folder id and the resource key:

```bash
rclone copy gDrive: /fm/data4/graphhopper-data/sonny-zips \
  --drive-root-folder-id 0BxphPoRgwhnoWkRoTFhMbTM3RDA \
  --drive-resource-key 0-wRe5bWl96pwvQ9tAfI9cQg \
  --include '*.zip' --transfers 8 --checkers 16 --progress

cd /fm/data4/graphhopper-data/sonny-zips
for z in *.zip; do
  unzip -o -q -j "$z" -d /fm/data4/graphhopper-data/sonny-dem || echo "FAILED: $z"
done
```

A complete 1" tile is exactly 3601 × 3601 int16 = 25934402 bytes, which makes
truncated or HTML-error-page downloads easy to spot:

```bash
find /fm/data4/graphhopper-data/sonny-dem -name '*.hgt' ! -size 25934402c
```

## A missing tile kills the import

This is the sharp edge. If a coordinate in the routed area falls in a 1° cell
with no tile, the provider tries to download it from the placeholder Google
Drive URL, which answers **HTTP 400 with an HTML body**. Java only raises
`FileNotFoundException` for 404/410, so a 400 surfaces as a plain `IOException`;
`downloadToFile` catches only `SocketTimeoutException` and
`FileNotFoundException`, so it reaches `updateHeightsFromFile`'s
`catch (Exception) → throw new RuntimeException(...)` and escapes `getEle`,
which guards only `FileNotFoundException`.

The import therefore **dies** on the first node in an uncovered cell —
`gh-update.sh` turns that into a hard failure and halts the schedule. It does
not degrade to flat terrain. (`SonnyProvider.main()` shows the author expected
this: its out-of-area probe is wrapped in `try/catch`.)

Two ways out:

- **`multi3`** — cgiar + gmted + sonny. It catches exactly that exception and
  falls back, which is why upstream recommends it for partial coverage. The cost
  is that CGIAR and GMTED then download tiles mid-import, and multi3 calls them
  outside any try, so their own failures are fatal instead.
- **Fill the gaps by hand**, which is what we do. Any `.hgt` in the cache
  directory works regardless of resolution — the tile width is derived from the
  file length (`width = sqrt(header)`), so a 3" SRTM tile (1201×1201,
  2884802 bytes) sits happily beside Sonny's 1" tiles (3601×3601, 25934402
  bytes) and simply gives that cell SRTM-grade elevation.

The old `srtmprovider/` cache is the gap list: `SRTMProvider` only ever
downloaded cells the extract actually touched, so `srtm-only minus sonny` is
precisely the set that would crash. **Do not delete `srtmprovider/`** — it is
the source for this.

```bash
cd /fm/data4/graphhopper-data/srtmprovider
comm -23 <(ls *.hgt.zip | sed 's/\.hgt\.zip//' | sort) \
         <(cd ../sonny-dem && ls *.hgt | sed 's/\.hgt//' | sort) \
  | while read t; do unzip -n -q -j "$t.hgt.zip" -d ../sonny-dem; done
```

As of the first Sonny import that filled 342 cells — 109 east of Sonny's 34°E
edge (eastern Turkey, the Caucasus) and 233 across North Africa and the southern
Mediterranean — giving 1398 tiles in total.

Residual risk: a future OSM update could add ways in a cell that neither set
covers. That import fails hard with `There was an issue with dem<key> looking up
the coordinates <lat>,<lon>` — the message names the coordinates, so re-run the
`comm` above, or drop in any `.hgt` for that cell, and restart.

Sonny covers Europe only, but generously: the folder starts at N27 and includes
the Canaries, Madeira, the Azores, Malta, Cyprus and the North African coastal
fringe, which covers most of what `limit.geojson` (lon −34.3…+46.9,
lat 29.0…71.4) reaches. Check the edges of the routed area after the first
import. If something out there ends up flat, the fix is GraphHopper's `multi3`
provider, which combines cgiar + gmted + sonny and falls back outside Sonny's
coverage.

## Changing elevation requires a full re-import

Elevation is baked into the graph at import time. Editing the provider,
the cache directory or the tiles has no effect on a running instance and no
effect on an existing graph. `gh-update.sh` already deletes the target graph
directory before importing (`rm -rf` on the resolved `graph-cache.<next>`), so
each update run does produce a genuinely clean graph — but it only rebuilds the
*inactive* instance, and only when Geofabrik has new data. After an elevation
change the other instance keeps its old graph until the run after that.

## Licence — attribution is required

The DTMs are published under **CC BY 4.0**. Redistribution and commercial use
are allowed, including public hosting, **provided Sonny is credited by name with
a link to <https://sonny.4lima.de/>**.

> **TODO (other repo):** freemap.sk must show this credit in its map/routing
> attribution. That lives in `freemap-v3-react`, not here. Until it is added, we
> are using the data outside its licence terms.

Note that GraphHopper's own `docs/core/elevation.md` still calls this data
"**not free** to use" and its `SonnyProvider` javadoc says it "cannot be used for
public hosting or redistribution". Both refer to
[issue #2823](https://github.com/graphhopper/graphhopper/issues/2823) and predate
the CC BY 4.0 release stated on sonny.4lima.de; the licence on the source site
governs. Worth re-checking there before any larger redistribution.

## GraphHopper version requirement

The `sonny` provider was added in
[PR #3183](https://github.com/graphhopper/graphhopper/pull/3183) (Nov 2025),
**after the 11.0 release**, and is not on the `11.x` branch. On the currently
deployed `graphhopper-web-11.0.jar` this config aborts the import immediately
with

```
java.lang.IllegalArgumentException: Did not find elevation provider: sonny
```

which `gh-update.sh` turns into a hard failure and a halt. A jar built from
`master` (or the first release that includes #3183) is required before these
configs can be used.
