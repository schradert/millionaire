//! dvdrip: DVD ripping on Kubernetes (docs/dvd-rip.md).
// The agent, controller and Job modes (later in the stack) use what is not called yet.
#![allow(dead_code)]

mod classify;
mod crd;
mod layout;
mod lsdvd;
mod naming;
#[cfg(test)]
mod testutil;
mod tracks;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Print the CustomResourceDefinitions (crds/dvd.trdos.me.yaml).
    Crds,
}

fn main() -> anyhow::Result<()> {
    match Cli::parse().command {
        Command::Crds => print!("{}", crd::crds_yaml()?),
    }
    Ok(())
}
