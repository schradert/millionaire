# Input: one HandBrake scan title. Output: the subtitle tracks to keep.
#
# DVDs often carry each subtitle stream in several positioning variants
# (Wide Screen / Letterbox / Pan&Scan) that HandBrake lists as separate
# tracks with identical text. Keep one per (language, kind): prefer the Wide
# Screen variant (matches the anamorphic 16:9 encode), then the plain one.

def variant:
  .Attributes as $a
  | if $a.Wide then 0
    elif ($a.Letterbox or $a.PanScan or $a["4By3"]) | not then 1
    elif $a.Letterbox then 2
    else 3 end;

[.SubtitleList // [] | .[]]
| group_by([.LanguageCode, .SourceName, .Attributes.Commentary, .Attributes.ClosedCaption,
            .Attributes.Forced, .Attributes.Large, .Attributes.Children])
| map(sort_by(variant) | first)
| sort_by(.TrackNumber)
