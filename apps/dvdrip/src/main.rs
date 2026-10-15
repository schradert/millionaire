//! dvdrip: DVD ripping on Kubernetes (docs/dvd-rip.md).
// The controller (next in the stack) uses what is not called yet.
#![allow(dead_code)]

mod agent;
mod backup;
mod classify;
mod crd;
mod damage;
mod encode;
mod inspect;
mod job;
mod kubeapi;
mod layout;
mod lsdvd;
mod makemkv;
mod metrics;
mod naming;
mod notify;
mod publish;
mod review;
#[cfg(test)]
mod testutil;
mod tool;
mod tracks;
mod web;

use std::io::IsTerminal;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Back up discs from this node's drives (the DaemonSet).
    Agent(agent::AgentArgs),
    /// Back up a disc (drive or image) into a directory, no API involved (formerly dvd-backup).
    Backup(agent::BackupArgs),
    /// Print a disc's label and fingerprint (drive or image).
    Probe(agent::ProbeArgs),
    /// Print the CustomResourceDefinitions (crds/dvd.trdos.me.yaml).
    Crds,
    /// Inspect, encode, mark damage, make review sheets and summarise one disc (the encode Job).
    Encode(job::EncodeArgs),
    /// Put a disc's ISO and encodes in the libraries as its spec says (the publish Job).
    Publish(job::PublishArgs),
}

fn init_logging() {
    use tracing_subscriber::{fmt, EnvFilter};
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    // JSON lines in pods (Loki), readable text on a terminal.
    if std::io::stderr().is_terminal() {
        fmt().with_env_filter(filter).with_writer(std::io::stderr).init();
    } else {
        fmt().json().flatten_event(true).with_env_filter(filter).with_writer(std::io::stderr).init();
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    if !matches!(cli.command, Command::Crds | Command::Probe(_)) {
        init_logging();
    }
    // Library files must stay group-writable for the other media apps (setgid dirs, group 101).
    #[cfg(unix)]
    unsafe {
        libc::umask(0o002);
    }
    match cli.command {
        Command::Crds => print!("{}", crd::crds_yaml()?),
        Command::Agent(a) => agent::run(a).await?,
        Command::Backup(a) => agent::backup_cmd(a).await?,
        Command::Probe(a) => agent::probe(a).await?,
        Command::Encode(a) => job::encode_cmd(a).await?,
        Command::Publish(a) => job::publish_cmd(a).await?,
    }
    Ok(())
}
