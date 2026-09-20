/**
 * Game engine for Connect Six (Connect6).
 *
 * Rules: 19x19 board. Black moves first and places ONE stone; after that each
 * player places TWO stones per turn. The first player to make six or more stones
 * in a row (horizontal, vertical or diagonal) wins.
 *
 * Board__c is a 361-character string, row by row: '.' empty, 'B' black, 'W' white.
 * Index = row * 19 + column.
 *
 * Runs WITHOUT sharing on purpose: the Connect Six Player permission set gives
 * read-only access to game records, so the only way to change a game is through
 * this class, which checks who is calling and whether the move is legal.
 * Every change publishes a Connect_Six_Move__e so both players' boards refresh.
 */
public without sharing class ConnectSixController {
    public static final Integer SIZE = 19;
    public static final Integer WIN_LENGTH = 6;

    @TestVisible
    private static final String EMPTY = '.';
    @TestVisible
    private static final String BLACK = 'B';
    @TestVisible
    private static final String WHITE = 'W';

    private static final String STATUS_WAITING = 'Waiting';
    private static final String STATUS_ACTIVE = 'Active';
    private static final String STATUS_FINISHED = 'Finished';

    // Row/column steps for the four line directions: across, down, and both diagonals.
    private static final List<List<Integer>> DIRECTIONS = new List<List<Integer>>{
        new List<Integer>{ 0, 1 },
        new List<Integer>{ 1, 0 },
        new List<Integer>{ 1, 1 },
        new List<Integer>{ 1, -1 }
    };

    /** Games anyone can join, plus the caller's own games in progress. */
    @AuraEnabled
    public static List<Connect_Six_Game__c> getLobbyGames() {
        Id me = UserInfo.getUserId();
        return [
            SELECT Id, Name, Status__c, Turn__c, Move_Count__c, LastModifiedDate,
                Black_Player__c, Black_Player__r.Name, White_Player__c, White_Player__r.Name
            FROM Connect_Six_Game__c
            WHERE Status__c = :STATUS_WAITING
                OR (Status__c = :STATUS_ACTIVE AND (Black_Player__c = :me OR White_Player__c = :me))
            ORDER BY LastModifiedDate DESC
            LIMIT 50
        ];
    }

    @AuraEnabled
    public static Connect_Six_Game__c getGame(Id gameId) {
        List<Connect_Six_Game__c> games = [
            SELECT Id, Name, Status__c, Turn__c, Board__c, Stones_Remaining__c, Move_Count__c,
                Last_Move__c, Winning_Line__c,
                Black_Player__c, Black_Player__r.Name,
                White_Player__c, White_Player__r.Name,
                Winner__c, Winner__r.Name
            FROM Connect_Six_Game__c
            WHERE Id = :gameId
        ];
        if (games.isEmpty()) {
            throw fail('Game not found.');
        }
        return games[0];
    }

    /** Creates a game with the caller as Black and waits for an opponent. */
    @AuraEnabled
    public static Connect_Six_Game__c createGame() {
        Connect_Six_Game__c game = new Connect_Six_Game__c(
            Black_Player__c = UserInfo.getUserId(),
            Status__c = STATUS_WAITING,
            Turn__c = 'Black',
            Stones_Remaining__c = 1,
            Move_Count__c = 0,
            Board__c = EMPTY.repeat(SIZE * SIZE)
        );
        insert game;
        announce(game.Id);
        return getGame(game.Id);
    }

    /** Joins a waiting game as White. */
    @AuraEnabled
    public static Connect_Six_Game__c joinGame(Id gameId) {
        Connect_Six_Game__c game = lock(gameId);
        if (game.Status__c != STATUS_WAITING) {
            throw fail('Someone has already joined this game.');
        }
        if (game.Black_Player__c == UserInfo.getUserId()) {
            throw fail('You can\'t join your own game. Ask another user to join it.');
        }
        game.White_Player__c = UserInfo.getUserId();
        game.Status__c = STATUS_ACTIVE;
        update game;
        announce(game.Id);
        return getGame(game.Id);
    }

    /** Places one stone for the caller. Row and column are 0-based. */
    @AuraEnabled
    public static Connect_Six_Game__c placeStone(Id gameId, Integer row, Integer col) {
        Connect_Six_Game__c game = lock(gameId);
        if (game.Status__c != STATUS_ACTIVE) {
            throw fail('This game isn\'t in progress.');
        }
        String color = colorOf(game, UserInfo.getUserId());
        if (color == null) {
            throw fail('You aren\'t a player in this game.');
        }
        if (game.Turn__c != colorName(color)) {
            throw fail('It\'s not your turn.');
        }
        if (row == null || col == null || row < 0 || row >= SIZE || col < 0 || col >= SIZE) {
            throw fail('That point is off the board.');
        }
        Integer idx = row * SIZE + col;
        String board = game.Board__c;
        if (board.substring(idx, idx + 1) != EMPTY) {
            throw fail('That point is already taken.');
        }

        board = board.substring(0, idx) + color + board.substring(idx + 1);
        game.Board__c = board;
        game.Move_Count__c = game.Move_Count__c + 1;

        // Track the stones of the current turn so the UI can highlight them.
        // Turns strictly alternate colors, so a new color prefix means a new turn.
        String prefix = color + ':';
        game.Last_Move__c = (game.Last_Move__c != null && game.Last_Move__c.startsWith(prefix))
            ? game.Last_Move__c + ',' + idx
            : prefix + idx;

        List<Integer> line = findLine(board, row, col, color);
        if (line != null) {
            game.Status__c = STATUS_FINISHED;
            game.Winner__c = UserInfo.getUserId();
            game.Winning_Line__c = String.join(line, ',');
            game.Stones_Remaining__c = 0;
        } else if (!board.contains(EMPTY)) {
            game.Status__c = STATUS_FINISHED; // Board full: no winner.
            game.Stones_Remaining__c = 0;
        } else {
            game.Stones_Remaining__c = game.Stones_Remaining__c - 1;
            if (game.Stones_Remaining__c <= 0) {
                game.Turn__c = game.Turn__c == 'Black' ? 'White' : 'Black';
                game.Stones_Remaining__c = 2;
            }
        }
        update game;
        announce(game.Id);
        return getGame(game.Id);
    }

    /** Resigns an active game (opponent wins) or cancels a game nobody has joined. */
    @AuraEnabled
    public static Connect_Six_Game__c resign(Id gameId) {
        Connect_Six_Game__c game = lock(gameId);
        String color = colorOf(game, UserInfo.getUserId());
        if (color == null) {
            throw fail('You aren\'t a player in this game.');
        }
        if (game.Status__c == STATUS_FINISHED) {
            throw fail('This game is already over.');
        }
        game.Status__c = STATUS_FINISHED;
        game.Stones_Remaining__c = 0;
        game.Winner__c = color == BLACK ? game.White_Player__c : game.Black_Player__c;
        update game;
        announce(game.Id);
        return getGame(game.Id);
    }

    /**
     * Returns the sorted board indexes of a line of WIN_LENGTH or more stones
     * through (row, col), or null if the stone just placed doesn't win.
     */
    @TestVisible
    private static List<Integer> findLine(String board, Integer row, Integer col, String color) {
        for (List<Integer> dir : DIRECTIONS) {
            List<Integer> line = new List<Integer>{ row * SIZE + col };
            for (Integer sign : new List<Integer>{ 1, -1 }) {
                Integer r = row + dir[0] * sign;
                Integer c = col + dir[1] * sign;
                while (r >= 0 && r < SIZE && c >= 0 && c < SIZE && board.substring(r * SIZE + c, r * SIZE + c + 1) == color) {
                    line.add(r * SIZE + c);
                    r += dir[0] * sign;
                    c += dir[1] * sign;
                }
            }
            if (line.size() >= WIN_LENGTH) {
                line.sort();
                return line;
            }
        }
        return null;
    }

    private static Connect_Six_Game__c lock(Id gameId) {
        // FOR UPDATE serializes simultaneous clicks from both players.
        List<Connect_Six_Game__c> games = [
            SELECT Id, Status__c, Turn__c, Board__c, Stones_Remaining__c, Move_Count__c,
                Last_Move__c, Black_Player__c, White_Player__c
            FROM Connect_Six_Game__c
            WHERE Id = :gameId
            FOR UPDATE
        ];
        if (games.isEmpty()) {
            throw fail('Game not found.');
        }
        return games[0];
    }

    private static String colorOf(Connect_Six_Game__c game, Id userId) {
        if (game.Black_Player__c == userId) {
            return BLACK;
        }
        if (game.White_Player__c == userId) {
            return WHITE;
        }
        return null;
    }

    private static String colorName(String color) {
        return color == BLACK ? 'Black' : 'White';
    }

    private static void announce(Id gameId) {
        EventBus.publish(new Connect_Six_Move__e(Game_Id__c = gameId));
    }

    private static AuraHandledException fail(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message); // Makes getMessage() return the text in tests.
        return e;
    }
}
