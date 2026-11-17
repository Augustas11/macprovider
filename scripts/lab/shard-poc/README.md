# Two-Mac model split over Tailscale (issue #2417 test)

This folder runs a one-session test: one model, split in two halves, served by
two Macs at two different places. The operator's Mac runs the first half (the
head). Your Mac runs the second half (the member). The head sends a fixed set of
test prompts and measures speed. That is all.

It is an unpaid experiment. There is no account, no token and no sign-up. Your
Mac does not join the MacProvider network and serves no one else.

## What you need

- A Mac with Apple Silicon (M1 or later), macOS 14 or later.
- 8 GB of memory or more (16 GB is more comfortable), about 3 GB of it free
  during the test, and 5 GB of free disk.
- Tailscale installed and signed in on that Mac.
- `git` (macOS offers to install it the first time you type `git`). Without
  git, download the repository ZIP from GitHub ("Code", "Download ZIP"), unzip
  it, and run the same `bash .../scripts/lab/shard-poc/member.sh` line from it.

## Tailscale sharing

In the Tailscale admin console, open Machines, pick your Mac, choose
"Share...", and send the invite link to the operator. The operator's account
can then reach that one Mac only, not the rest of your tailnet, and you can
remove the share at any time.

The operator sends you the head Mac's Tailscale address (it starts with `100.`).

## The one command

```bash
git clone -b lab/2417-cross-owner-shard-poc https://github.com/Augustas11/macprovider.git
bash macprovider/scripts/lab/shard-poc/member.sh --peer <head address>
```

Keep the Terminal window open until the operator says the test is done.

## What you will see

1. Checks of your Mac (chip, macOS, memory, disk, Tailscale address).
2. A download of the public `macprovider-cli` release from GitHub (about
   116 MB). The script checks its signature and checksum the same way the
   public installer does.
3. A download of the test model, `mlx-community/Llama-3.2-3B-Instruct-4bit`
   from HuggingFace (1.8 GB). The script checks it against the signed catalog
   hash in this repository.
4. A box that says `RUNNING`, your Mac's half is loaded (layers 14 to 27) and
   is waiting for the head. After that, lines appear when the head connects.

Time: the downloads (about 2 GB) take a few minutes on a fast line and longer on a slow one; loading takes about
10 seconds; the test itself takes a few minutes. Memory: about 1 to 2 GB
while it runs.

Everything goes into `~/shard-poc`. If MacProvider or Malibu is already
installed on your Mac, the script leaves it alone and uses its own folder,
config and ports (18191 and 47101).

## Stop and clean up

- Stop: press Ctrl-C in the Terminal window.
- Remove everything the test created: `bash macprovider/scripts/lab/shard-poc/member.sh --cleanup`
  then delete the `macprovider` folder you cloned, and remove the Tailscale share.

## The log

The script writes a log to `~/shard-poc/member/member-<date>.log` and, when it
stops, a copy with your Tailscale addresses and home folder path removed:
`member-<date>.share.log`. Please attach the `.share.log` file to issue #2417.

## What is shared and what is not

- Your Mac only sees fixed prompts: the test prompts in `prompts.json` in this
  folder and one short startup probe built into the CLI. No other prompts are sent.
- Your Mac computes on the model's hidden states for those prompts. Someone who
  runs the member half can reconstruct the prompts from those hidden states.
  That is why only fixed, public test prompts are used.
- The link between the two Macs is not encrypted by the CLI, and in this test
  mode the CLI does not check which Mac connects to yours. Frames carry an
  HMAC, which detects changes but hides nothing. Tailscale encrypts the link and
  limits who can reach your Mac. That is why the script refuses to listen on
  anything but your Tailscale address.
- The script sends nothing anywhere else. It reads from GitHub and HuggingFace
  only to download the CLI and the model.

## For the operator (head side)

```bash
bash scripts/lab/shard-poc/head.sh --member <member address>   # the two-Mac test
bash scripts/lab/shard-poc/head.sh --baseline                  # same model, this Mac alone
bash scripts/lab/shard-poc/head.sh --rehearse                  # head and member on this Mac
bash scripts/lab/shard-poc/head.sh --cleanup
```

`head.sh` prints a markdown table (total tok/s, per-request tok/s, TTFT at 1,
4 and 8 requests in flight) and writes `results.json` under
`~/shard-poc/results/`. Neither script pauses, stops or restarts any running
provider; on a Mac that serves live traffic, book the GPU first.

The link round trip in the table is an ICMP ping over Tailscale, plus the
`tailscale ping` path (direct or relayed). The CLI measures the stage link's
own round trip but, in this `--no-join` mode, reports it only to a coordinator.

Link supervision defaults are set for an internet link: heartbeat 250 ms x 8
misses (2 s) and a 1500 ms decode-hop deadline (cable defaults: 100 ms x 3,
500 ms). Change them with `--heartbeat-ms`, `--heartbeat-misses`,
`--decode-hop-ms`, `--prefill-chunk-ms` and `--replay-ms`; both sides must use
the same values, and so must `--max-sequences` and `--max-context`.
