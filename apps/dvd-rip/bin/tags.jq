# Input: `mkvmerge -J` of a HandBrake encode. $hb: that title from the
# HandBrake scan; $subs: the subtitle tracks passed to --subtitle (in order,
# see select-subs.jq); $title: segment title. Output: mkvpropedit args, one
# per line, naming every track and setting Matroska flags (default /
# commentary / visual-impaired / hearing-impaired / forced) from the DVD's
# content codes — HandBrake keeps languages but not these flags.
#
# Output tracks are in source order, so audio i <-> $hb.AudioList[i] and
# subtitle k <-> $subs[k]; if counts don't line up we leave that track type
# alone rather than mislabel it.

def layout: {"1": "Mono", "2": "Stereo", "6": "5.1", "8": "7.1"}[tostring] // "\(.)ch";
def flag($b): if $b then "1" else "0" end;
# "English Director's Commentary (Wide Screen) [VOBSUB]" -> "English"
def lang: .Language | sub("[ ,(\\[].*$"; "");

[.tracks[] | select(.type == "audio")] as $a
| [.tracks[] | select(.type == "subtitles")] as $s
| ($hb.AudioList // []) as $al
| ($al | map(.Attributes.Commentary or .Attributes.AltCommentary or .Attributes.VisuallyImpaired | not)
       | index(true) // 0) as $default
| ["--edit", "info", "--set", "title=\($title)"]
  + if ($a | length) == ($al | length) then
      [range(0; $a | length) as $i
       | $al[$i] as $d
       | ($d.Attributes.Commentary or $d.Attributes.AltCommentary) as $comm
       | $d.Attributes.VisuallyImpaired as $ad
       | "--edit", "track:a\($i + 1)",
         "--set", "name=\(if $comm then "Commentary - " elif $ad then "Audio Description - " else "" end)\($d.ChannelCount | layout)\(if $d.Description | test("Dolby Surround") then " (Dolby Surround)" else "" end)",
         "--set", "flag-default=\(flag($i == $default))",
         "--set", "flag-commentary=\(flag($comm))",
         "--set", "flag-visual-impaired=\(flag($ad))"]
    else [] end
  + if ($s | length) == ($subs | length) then
      [range(0; $s | length) as $k
       | $subs[$k].Attributes as $at
       | "--edit", "track:s\($k + 1)",
         "--set", "name=\($subs[$k] | lang)\(if $at.Commentary then " (Commentary)" elif $at.ClosedCaption then " (CC)" elif $at.Forced then " (Forced)" elif $at.Large then " (Large)" elif $at.Children then " (Children)" else "" end)",
         "--set", "flag-default=0",
         "--set", "flag-commentary=\(flag($at.Commentary))",
         "--set", "flag-hearing-impaired=\(flag($at.ClosedCaption))",
         "--set", "flag-forced=\(flag($at.Forced))"]
    else [] end
| .[]
