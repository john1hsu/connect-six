import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import LightningConfirm from 'lightning/confirm';
import userId from '@salesforce/user/Id';
import getLobbyGames from '@salesforce/apex/ConnectSixController.getLobbyGames';
import getGame from '@salesforce/apex/ConnectSixController.getGame';
import createGame from '@salesforce/apex/ConnectSixController.createGame';
import joinGame from '@salesforce/apex/ConnectSixController.joinGame';
import placeStone from '@salesforce/apex/ConnectSixController.placeStone';
import resign from '@salesforce/apex/ConnectSixController.resign';

const SIZE = 19;
const EMPTY = '.';
const CHANNEL = '/event/Connect_Six_Move__e';
const STAR_POINTS = new Set();
[3, 9, 15].forEach((r) => [3, 9, 15].forEach((c) => STAR_POINTS.add(r * SIZE + c)));

// Compare Ids regardless of 15/18-character form.
const sameId = (a, b) => !!a && !!b && a.substring(0, 15) === b.substring(0, 15);
const indexes = (csv) => new Set(csv ? csv.split(',').map(Number) : []);
const nameOf = (rel, fallback) => (rel && rel.Name) || fallback;

export default class ConnectSix extends LightningElement {
    lobbyGames = [];
    game;
    busy = false;
    subscription;

    connectedCallback() {
        this.loadLobby();
        onError((error) => {
            // eslint-disable-next-line no-console
            console.error('Connect Six streaming error', JSON.stringify(error));
        });
        subscribe(CHANNEL, -1, (message) => this.handleEvent(message)).then((sub) => {
            this.subscription = sub;
        });
    }

    disconnectedCallback() {
        if (this.subscription) {
            unsubscribe(this.subscription);
        }
    }

    // ---------- Real-time updates ----------

    handleEvent(message) {
        const payload = message && message.data && message.data.payload;
        const gameId = payload && payload.Game_Id__c;
        if (this.game) {
            if (sameId(gameId, this.game.Id)) {
                this.refreshGame();
            }
        } else {
            this.loadLobby();
        }
    }

    async loadLobby() {
        try {
            this.lobbyGames = await getLobbyGames();
        } catch (error) {
            this.toastError(error);
        }
    }

    async refreshGame() {
        if (!this.game) return;
        try {
            this.game = await getGame({ gameId: this.game.Id });
        } catch (error) {
            this.toastError(error);
        }
    }

    // Runs one server action at a time and shows the game it returns.
    async run(action) {
        if (this.busy) return;
        this.busy = true;
        try {
            this.game = await action();
        } catch (error) {
            this.toastError(error);
            await this.refreshGame();
        } finally {
            this.busy = false;
        }
    }

    // ---------- Lobby ----------

    get hasLobbyGames() {
        return this.lobbyGames.length > 0;
    }

    get lobbyRows() {
        return this.lobbyGames.map((g) => {
            const black = nameOf(g.Black_Player__r, 'Unknown');
            const white = nameOf(g.White_Player__r, null);
            const mine = sameId(g.Black_Player__c, userId) || sameId(g.White_Player__c, userId);
            let detail;
            if (g.Status__c === 'Waiting') {
                detail = mine ? 'Waiting for someone to join' : `${black} is looking for an opponent`;
            } else {
                const myTurn =
                    (g.Turn__c === 'Black' && sameId(g.Black_Player__c, userId)) ||
                    (g.Turn__c === 'White' && sameId(g.White_Player__c, userId));
                detail = `${black} vs ${white} · ${myTurn ? 'your turn' : 'their turn'}`;
            }
            const join = g.Status__c === 'Waiting' && !mine;
            return {
                id: g.Id,
                name: g.Name,
                detail,
                action: join ? 'join' : 'open',
                actionLabel: join ? 'Join' : 'Open',
                variant: join ? 'brand' : 'neutral'
            };
        });
    }

    handleNewGame() {
        this.run(() => createGame());
    }

    handleOpen(event) {
        const { id, action } = event.currentTarget.dataset;
        this.run(() => (action === 'join' ? joinGame({ gameId: id }) : getGame({ gameId: id })));
    }

    handleBack() {
        this.game = undefined;
        this.loadLobby();
    }

    // ---------- Game ----------

    get myColor() {
        if (!this.game) return null;
        if (sameId(this.game.Black_Player__c, userId)) return 'B';
        if (sameId(this.game.White_Player__c, userId)) return 'W';
        return null;
    }

    get isMyTurn() {
        const g = this.game;
        return (
            !!g &&
            g.Status__c === 'Active' &&
            ((g.Turn__c === 'Black' && this.myColor === 'B') || (g.Turn__c === 'White' && this.myColor === 'W'))
        );
    }

    get blackName() {
        return nameOf(this.game.Black_Player__r, 'Black');
    }

    get whiteName() {
        return nameOf(this.game.White_Player__r, 'Waiting for opponent…');
    }

    get statusText() {
        const g = this.game;
        if (g.Status__c === 'Waiting') {
            return this.myColor ? 'Waiting for someone to join from their Connect Six tab' : 'Waiting for players';
        }
        if (g.Status__c === 'Finished') {
            if (!g.Winner__c) return 'Game over';
            return sameId(g.Winner__c, userId) ? 'You win!' : `${nameOf(g.Winner__r, 'Your opponent')} wins`;
        }
        if (this.isMyTurn) {
            const n = g.Stones_Remaining__c;
            return `Your turn: place ${n} stone${n === 1 ? '' : 's'}`;
        }
        const mover = g.Turn__c === 'Black' ? this.blackName : this.whiteName;
        return `${mover}'s turn`;
    }

    get statusClass() {
        return this.isMyTurn ? 'status status_active' : 'status';
    }

    get boardClass() {
        return this.myColor === 'W' ? 'board as-white' : 'board as-black';
    }

    get canResign() {
        return !!this.game && !!this.myColor && this.game.Status__c !== 'Finished';
    }

    get resignLabel() {
        return this.game.Status__c === 'Waiting' ? 'Cancel game' : 'Resign';
    }

    get rows() {
        const g = this.game;
        const board = g.Board__c || EMPTY.repeat(SIZE * SIZE);
        const last = indexes(g.Last_Move__c ? g.Last_Move__c.split(':')[1] : null);
        const win = indexes(g.Winning_Line__c);
        const canPlay = this.isMyTurn && !this.busy;
        const rows = [];
        for (let r = 0; r < SIZE; r++) {
            const cells = [];
            for (let c = 0; c < SIZE; c++) {
                const idx = r * SIZE + c;
                const stone = board.charAt(idx);
                let cls = 'cell';
                if (r === 0) cls += ' top';
                if (r === SIZE - 1) cls += ' bottom';
                if (c === 0) cls += ' left';
                if (c === SIZE - 1) cls += ' right';

                let stoneCls = 'stone';
                if (stone === 'B') stoneCls += ' black';
                else if (stone === 'W') stoneCls += ' white';
                else {
                    if (STAR_POINTS.has(idx)) stoneCls += ' star';
                    if (canPlay) cls += ' playable';
                }
                if (last.has(idx)) stoneCls += ' last';
                if (win.has(idx)) stoneCls += ' win';

                cells.push({ key: idx, idx, cls, stoneCls, label: `Row ${r + 1}, column ${c + 1}` });
            }
            rows.push({ key: r, cells });
        }
        return rows;
    }

    handleCellClick(event) {
        const idx = Number(event.currentTarget.dataset.idx);
        const board = this.game.Board__c;
        if (!this.isMyTurn || this.busy || board.charAt(idx) !== EMPTY) return;

        // Show the stone right away; the server's answer replaces this.
        this.game = { ...this.game, Board__c: board.slice(0, idx) + this.myColor + board.slice(idx + 1) };
        const row = Math.floor(idx / SIZE);
        const col = idx % SIZE;
        this.run(() => placeStone({ gameId: this.game.Id, row, col }));
    }

    async handleResign() {
        const waiting = this.game.Status__c === 'Waiting';
        const ok = await LightningConfirm.open({
            label: waiting ? 'Cancel this game?' : 'Resign this game?',
            message: waiting ? 'Nobody has joined yet. The game will be closed.' : 'Your opponent will be declared the winner.',
            theme: 'warning'
        });
        if (ok) {
            const gameId = this.game.Id;
            this.run(() => resign({ gameId }));
        }
    }

    toastError(error) {
        const message = (error && error.body && error.body.message) || (error && error.message) || 'Something went wrong.';
        this.dispatchEvent(new ShowToastEvent({ title: 'Connect Six', message, variant: 'error' }));
    }
}
