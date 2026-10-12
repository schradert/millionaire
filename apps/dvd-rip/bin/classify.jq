# Input: lsdvd -Ox converted by xq. Normalise lsdvd's XML (single children aren't arrays, numbers are strings)
# and classify. Roles:
#   main     HandBrake's main-feature pick (or --main)
#   alt      ~same runtime as main, different title (fullscreen/extended cut)
#   dup      same VTS + identical cell layout as an earlier kept title
#   playall  runtime ≈ sum of ≥2 extras in the same VTS ("Play All" chains)
#   part     an extra that's a piece of the main feature when the main is
#            itself a "Play All" (compilation discs)
#   stub     < STUB_MAX s (menu stubs, black frames)
#   short    < EXTRA_MIN s (studio logos, bumpers, warnings)
#   extra    everything else (featurettes, trailers, deleted scenes…)
def arr: if . == null then [] elif type == "array" then . else [.] end;
def num: tonumber? // 0;
[.lsdvd.track | arr[] | {
   title: (.ix | num),
   seconds: (.length | num),
   vts: (.vts | num),
   ttn: (.ttn | num),
   aspect: .aspect,
   fps: (.fps | num),
   angles: (.angles | num),
   chapters: [.chapter | arr[] | .length | num],
   cells: [.cell | arr[] | .length | num | . * 10 | round],
   audio: [.audio | arr[] | {lang: .langcode, language, format, channels: (.channels | num), content}],
   subs: [.subp | arr[] | {lang: .langcode, language, content}]
 }]
| sort_by(.title)
| (map(select(.title == $main)) | first | .seconds // 0) as $mainlen
| reduce .[] as $t ([];
    . as $kept
    | ($kept | map(select(.role | IN("main", "alt", "extra", "short")))) as $live
    | ($t
       | .role =
           if .title == $main then "main"
           elif .seconds < $stub then "stub"
           elif any($live[]; .vts == $t.vts and .cells == $t.cells) then "dup"
           elif $mainlen > 0 and ((.seconds - $mainlen) | fabs) < ($mainlen * 0.02) then "alt"
           elif .seconds < $extra then "short"
           else "extra" end) as $c
    | $kept + [$c])
# Widescreen/fullscreen pairs: HandBrake sometimes picks the 4:3 cut as the
# main feature; make the 16:9 one main and the 4:3 one the alternate.
| (map(select(.role == "alt" and .aspect == "16/9")) | first | .title) as $wide
| if $wide != null and any(.[]; .role == "main" and .aspect == "4/3")
  then map(if .role == "main" then .role = "alt" elif .title == $wide then .role = "main" else . end)
  else . end
# Compilation discs (e.g. three TV specials): when the main feature itself is
# a "Play All" of ≥2 other titles in its VTS, those titles are parts of it —
# don't encode the same video twice.
| . as $all
| (map(select(.role == "main")) | first) as $m
| (if $m == null then [] else [$all[] | select(.role == "extra" and .vts == $m.vts and .seconds < $m.seconds)] end) as $parts
| if ($parts | length) >= 2 and ((($parts | map(.seconds) | add) - $m.seconds) | fabs) < 3
  then map(if .title as $t | any($parts[]; .title == $t) then .role = "part" | .part_of = $m.title else . end)
  else . end
# Second pass: a title in the same VTS whose runtime matches the sum of
# ≥2 other extras there is a "Play All" chain of them.
| . as $all
| map(if .role == "extra" then
        . as $t
        | [$all[] | select(.role == "extra" and .vts == $t.vts and .title != $t.title and .seconds < $t.seconds)] as $parts
        | if ($parts | length) >= 2 and ((($parts | map(.seconds) | add) - $t.seconds) | fabs) < 3
          then .role = "playall" | .playall_of = ($parts | map(.title)) else . end
      else . end)
