//! Letterboxd's import format (https://letterboxd.com/about/importing-data/): UTF-8 CSV whose
//! header names the columns it knows; `tmdbID` is an exact match, the rest is informational.

use crate::trakt::Play;
use std::collections::{BTreeMap, BTreeSet};

pub const HEADER: &str = "tmdbID,imdbID,Title,Year,WatchedDate,Rating10,Rewatch";

/// Letterboxd documents backslash-escaped quotes where RFC 4180 doubles them. Quotes never carry
/// meaning here (the tmdbID does the matching), so they are swapped for apostrophes, which parse
/// the same under either rule.
fn field(s: &str) -> String {
    let s = s.replace('"', "'").replace(['\r', '\n'], " ");
    if s.contains(',') {
        format!("\"{s}\"")
    } else {
        s
    }
}

pub struct Batch {
    pub csv: String,
    /// "Title (Year)" per row, oldest first, for the notification.
    pub films: Vec<String>,
    /// Plays that had no TMDB id and so could not be matched exactly.
    pub skipped: Vec<String>,
}

/// `plays` in any order; rows come out oldest first so the diary reads in order. `seen` holds the
/// films already in the diary and is extended as rows are emitted, so a film played twice in one
/// batch is a rewatch the second time.
pub fn build(plays: &[Play], ratings: &BTreeMap<u64, u8>, seen: &mut BTreeSet<u64>) -> Batch {
    let mut sorted: Vec<&Play> = plays.iter().collect();
    sorted.sort_by(|a, b| a.watched_at.cmp(&b.watched_at).then(a.id.cmp(&b.id)));
    let mut csv = String::from(HEADER);
    csv.push('\n');
    let (mut films, mut skipped) = (Vec::new(), Vec::new());
    for p in sorted {
        let label = match p.movie.year {
            Some(y) => format!("{} ({y})", p.movie.title),
            None => p.movie.title.clone(),
        };
        let Some(tmdb) = p.movie.ids.tmdb else {
            skipped.push(label);
            continue;
        };
        let rewatch = !seen.insert(tmdb);
        csv.push_str(&format!(
            "{tmdb},{},{},{},{},{},{}\n",
            field(p.movie.ids.imdb.as_deref().unwrap_or("")),
            field(&p.movie.title),
            p.movie.year.map(|y| y.to_string()).unwrap_or_default(),
            p.watched_at.get(..10).unwrap_or(""),
            ratings.get(&p.movie.ids.trakt).map(|r| r.to_string()).unwrap_or_default(),
            rewatch,
        ));
        films.push(label);
    }
    Batch { csv, films, skipped }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::trakt::{Ids, Movie};

    fn play(id: u64, at: &str, title: &str, year: Option<u32>, tmdb: Option<u64>) -> Play {
        Play { id, watched_at: at.into(), movie: Movie { title: title.into(), year, ids: Ids { trakt: id * 10, imdb: Some(format!("tt{id}")), tmdb } } }
    }

    #[test]
    fn orders_oldest_first_marks_rewatches_and_skips_unmatched() {
        let plays = vec![
            play(3, "2026-03-03T20:00:00.000Z", "Heat", Some(1995), Some(949)),
            play(1, "2026-01-01T20:00:00.000Z", "Heat", Some(1995), Some(949)),
            play(2, "2026-02-02T20:00:00.000Z", "Obscure, The", Some(2020), None),
            play(4, "2026-04-04T20:00:00.000Z", "Say \"Cheese\"", None, Some(5)),
        ];
        let ratings = BTreeMap::from([(10, 9u8)]);
        let mut seen = BTreeSet::new();
        let b = build(&plays, &ratings, &mut seen);
        let lines: Vec<&str> = b.csv.lines().collect();
        assert_eq!(lines[0], HEADER);
        assert_eq!(lines[1], "949,tt1,Heat,1995,2026-01-01,9,false");
        assert_eq!(lines[2], "949,tt3,Heat,1995,2026-03-03,,true");
        assert_eq!(lines[3], "5,tt4,Say 'Cheese',,2026-04-04,,false");
        assert_eq!(lines.len(), 4);
        assert_eq!(b.films, ["Heat (1995)", "Heat (1995)", "Say \"Cheese\""]);
        assert_eq!(b.skipped, ["Obscure, The (2020)"]);
        assert!(seen.contains(&949) && seen.contains(&5));
    }

    #[test]
    fn ratings_join_by_trakt_id_and_commas_are_quoted() {
        let plays = vec![play(1, "2026-01-01T20:00:00.000Z", "Hello, World", Some(2001), Some(1))];
        let b = build(&plays, &BTreeMap::from([(10, 7u8)]), &mut BTreeSet::new());
        assert_eq!(b.csv.lines().nth(1).unwrap(), "1,tt1,\"Hello, World\",2001,2026-01-01,7,false");
    }

    #[test]
    fn films_already_seen_are_rewatches() {
        let plays = vec![play(1, "2026-01-01T20:00:00.000Z", "Heat", Some(1995), Some(949))];
        let b = build(&plays, &BTreeMap::new(), &mut BTreeSet::from([949]));
        assert!(b.csv.contains(",true\n"));
    }
}
