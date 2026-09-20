@IsTest
private class ConnectSixControllerTest {
    // Users are inserted first; all game DML then runs inside System.runAs,
    // which avoids mixed DML errors (User is a setup object).
    private static User makeUser(String lastName) {
        String unique = String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User u = new User(
            LastName = lastName,
            Alias = ('c6' + unique).left(8),
            Email = 'c6' + unique + '@example.com',
            Username = 'c6' + unique + '@connectsix.test',
            ProfileId = UserInfo.getProfileId(),
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert u;
        return u;
    }

    private static Connect_Six_Game__c startGame(User black, User white) {
        Connect_Six_Game__c game;
        System.runAs(black) {
            game = ConnectSixController.createGame();
        }
        System.runAs(white) {
            game = ConnectSixController.joinGame(game.Id);
        }
        return game;
    }

    private static Connect_Six_Game__c play(User u, Id gameId, Integer row, Integer col) {
        Connect_Six_Game__c game;
        System.runAs(u) {
            game = ConnectSixController.placeStone(gameId, row, col);
        }
        return game;
    }

    private static String errorFrom(User u, Id gameId, Integer row, Integer col) {
        try {
            play(u, gameId, row, col);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void createAndJoin() {
        User black = makeUser('Black');
        User white = makeUser('White');

        Test.startTest();
        Connect_Six_Game__c created;
        System.runAs(black) {
            created = ConnectSixController.createGame();
        }
        List<Connect_Six_Game__c> lobby;
        System.runAs(white) {
            lobby = ConnectSixController.getLobbyGames();
        }
        Connect_Six_Game__c joined;
        System.runAs(white) {
            joined = ConnectSixController.joinGame(created.Id);
        }
        Test.stopTest();

        Assert.areEqual('Waiting', created.Status__c);
        Assert.areEqual(361, created.Board__c.length());
        Assert.areEqual(1, lobby.size());
        Assert.areEqual('Active', joined.Status__c);
        Assert.areEqual(white.Id, joined.White_Player__c);
        Assert.areEqual('Black', joined.Turn__c);
    }

    @IsTest
    static void cannotJoinOwnOrFullGame() {
        User black = makeUser('Black');
        User white = makeUser('White');
        User third = makeUser('Third');
        Connect_Six_Game__c game;
        System.runAs(black) {
            game = ConnectSixController.createGame();
        }

        Test.startTest();
        String ownError;
        System.runAs(black) {
            try {
                ConnectSixController.joinGame(game.Id);
            } catch (AuraHandledException e) {
                ownError = e.getMessage();
            }
        }
        System.runAs(white) {
            ConnectSixController.joinGame(game.Id);
        }
        String fullError;
        System.runAs(third) {
            try {
                ConnectSixController.joinGame(game.Id);
            } catch (AuraHandledException e) {
                fullError = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.isTrue(ownError.contains('your own game'), ownError);
        Assert.isTrue(fullError.contains('already joined'), fullError);
    }

    @IsTest
    static void turnsAlternateOneThenTwoStones() {
        User black = makeUser('Black');
        User white = makeUser('White');
        Connect_Six_Game__c game = startGame(black, white);

        Test.startTest();
        Connect_Six_Game__c afterBlack = play(black, game.Id, 9, 9);
        Connect_Six_Game__c afterWhite1 = play(white, game.Id, 0, 0);
        Connect_Six_Game__c afterWhite2 = play(white, game.Id, 0, 1);
        Test.stopTest();

        Assert.areEqual('White', afterBlack.Turn__c, 'Black places only one stone on the first turn');
        Assert.areEqual(2, afterBlack.Stones_Remaining__c);
        Assert.areEqual('White', afterWhite1.Turn__c);
        Assert.areEqual(1, afterWhite1.Stones_Remaining__c);
        Assert.areEqual('Black', afterWhite2.Turn__c);
        Assert.areEqual('W:0,1', afterWhite2.Last_Move__c);
        Assert.areEqual(3, afterWhite2.Move_Count__c);
        Assert.areEqual('B', afterWhite2.Board__c.substring(180, 181));
    }

    @IsTest
    static void illegalMovesAreRejected() {
        User black = makeUser('Black');
        User white = makeUser('White');
        User outsider = makeUser('Outsider');
        Connect_Six_Game__c game = startGame(black, white);

        Test.startTest();
        String wrongTurn = errorFrom(white, game.Id, 0, 0);
        String offBoard = errorFrom(black, game.Id, 19, 0);
        String notPlayer = errorFrom(outsider, game.Id, 1, 1);
        play(black, game.Id, 0, 0);
        String taken = errorFrom(white, game.Id, 0, 0);
        Test.stopTest();

        Assert.isTrue(wrongTurn.contains('not your turn'), wrongTurn);
        Assert.isTrue(offBoard.contains('off the board'), offBoard);
        Assert.isTrue(notPlayer.contains('aren\'t a player'), notPlayer);
        Assert.isTrue(taken.contains('already taken'), taken);
    }

    @IsTest
    static void blackWinsWithSixInARow() {
        User black = makeUser('Black');
        User white = makeUser('White');
        Connect_Six_Game__c game = startGame(black, white);

        Test.startTest();
        play(black, game.Id, 0, 0);
        play(white, game.Id, 5, 0);
        play(white, game.Id, 5, 1);
        play(black, game.Id, 0, 1);
        play(black, game.Id, 0, 2);
        play(white, game.Id, 5, 2);
        play(white, game.Id, 5, 3);
        play(black, game.Id, 0, 3);
        play(black, game.Id, 0, 4);
        play(white, game.Id, 10, 0);
        play(white, game.Id, 10, 1);
        Connect_Six_Game__c result = play(black, game.Id, 0, 5);
        String afterEnd = errorFrom(white, game.Id, 18, 18);
        Test.stopTest();

        Assert.areEqual('Finished', result.Status__c);
        Assert.areEqual(black.Id, result.Winner__c);
        Assert.areEqual('0,1,2,3,4,5', result.Winning_Line__c);
        Assert.isTrue(afterEnd.contains('isn\'t in progress'), afterEnd);
    }

    @IsTest
    static void findsDiagonalLines() {
        String board = ConnectSixController.EMPTY.repeat(361);
        // Anti-diagonal from (2,10) down-left to (7,5).
        for (Integer i = 0; i < 6; i++) {
            Integer idx = (2 + i) * 19 + (10 - i);
            board = board.substring(0, idx) + ConnectSixController.WHITE + board.substring(idx + 1);
        }
        List<Integer> line = ConnectSixController.findLine(board, 4, 8, ConnectSixController.WHITE);
        Assert.areEqual(6, line.size());
        Assert.areEqual(2 * 19 + 10, line[0]);
        Assert.isNull(ConnectSixController.findLine(board, 4, 8, ConnectSixController.BLACK));
    }

    @IsTest
    static void resignAndCancel() {
        User black = makeUser('Black');
        User white = makeUser('White');
        Connect_Six_Game__c active = startGame(black, white);
        Connect_Six_Game__c waiting;
        System.runAs(black) {
            waiting = ConnectSixController.createGame();
        }

        Test.startTest();
        Connect_Six_Game__c resigned;
        System.runAs(white) {
            resigned = ConnectSixController.resign(active.Id);
        }
        Connect_Six_Game__c cancelled;
        System.runAs(black) {
            cancelled = ConnectSixController.resign(waiting.Id);
        }
        Test.stopTest();

        Assert.areEqual('Finished', resigned.Status__c);
        Assert.areEqual(black.Id, resigned.Winner__c);
        Assert.areEqual('Finished', cancelled.Status__c);
        Assert.isNull(cancelled.Winner__c);
    }
}
