# Connect Six for Salesforce

Two-player Connect Six (Connect6), built as an unlocked package. Players go head-to-head on a 19×19 board inside Lightning Experience, and moves show up on both screens in real time.

## Rules

- Black places **one** stone on the opening move.
- After that, each player places **two** stones per turn.
- The first player to get **six or more in a row** (across, down or diagonal) wins.

## What's in the package

| Component | Purpose |
|---|---|
| `Connect_Six_Game__c` | One record per game. Holds the board as a 361-character string (`.` empty, `B` black, `W` white). |
| `Connect_Six_Move__e` | Platform event published after every change, so open boards refresh. |
| `ConnectSixController` | Game engine: create, join, place a stone, resign. Checks every rule on the server. |
| `ConnectSixControllerTest` | Apex tests (needed for code coverage when you promote a version). |
| `connectSix` (LWC) | Lobby and board UI. Uses `lightning/empApi` for live updates. |
| `Connect_Six` tab | Holds the `connectSix` component. |
| `Connect_Six` app | Standalone Lightning app containing the tab. This is what players open from the App Launcher. |
| `Connect_Six_Player` permission set | Read-only access to games, plus access to the controller, event, tab and app. |

### Why the controller runs `without sharing`

Game records are **read-only** for players, which stops anyone from editing a board by hand. Every change goes through `ConnectSixController`. The controller checks that the caller is a player in the game, that it's their turn, and that the move is legal before it writes anything.

## Try it in a scratch org

```bash
sf org login web --set-default-dev-hub --alias devhub
sf org create scratch --definition-file config/project-scratch-def.json --alias c6 --set-default
sf project deploy start
sf org assign permset --name Connect_Six_Player
sf apex run test --class-names ConnectSixControllerTest --result-format human --code-coverage

# A second user to play against
sf org create user --definition-file config/player2-user-def.json --set-alias player2
sf org display user --target-org player2      # shows the generated password
sf org open
```

Open the **Connect Six** app from the App Launcher and click **New game**. Then log in as Player Two in a private or incognito window and click **Join**.

## Package it

```bash
# One time: creates the package and adds its alias to sfdx-project.json
sf package create --name "Connect Six" --package-type Unlocked --path force-app --no-namespace

# Each release
sf package version create --package "Connect Six" --installation-key-bypass --code-coverage --wait 20
sf package version promote --package "Connect Six@0.1.0-1"

# Install into any org
sf package install --package 04t... --target-org <alias> --wait 10
sf org assign permset --name Connect_Six_Player --target-org <alias>
```

Grant **Connect Six Player** to everyone who should be able to play.
