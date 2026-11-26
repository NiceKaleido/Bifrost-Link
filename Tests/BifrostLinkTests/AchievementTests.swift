import Testing
import Foundation
@testable import BifrostLink

@Suite struct AchievementTests {
    @Test func parsesAPIResponses() throws {
        let completion = #"{"Count":1,"Total":1,"Results":[{"GameID":"14402","Title":"Pokémon Emerald","ImageIcon":"/Images/067895.png","ConsoleID":5,"ConsoleName":"Game Boy Advance","MaxPossible":"77","NumAwarded":"10","NumAwardedHardcore":"8","MostRecentAwardedDate":"2026-11-01T18:30:00+00:00","HighestAwardKind":"beaten-hardcore"}]}"#
        let page = try JSONSerialization.jsonObject(with: Data(completion.utf8)) as! [String: Any]
        let game = try #require(AchievementsHub.progress(from: (page["Results"] as! [[String: Any]])[0]))
        #expect(game.id == 14402 && game.total == 77 && game.earned == 10 && game.awardLabel == "Beaten (hardcore)" && game.lastUnlock != nil)
        let ach = AchievementsHub.achievement(from: ["ID": 1, "Title": "A", "Description": "d", "Points": 5, "BadgeName": "250336", "DisplayOrder": 1, "DateEarned": "2026-11-02 10:00:00"])
        #expect(ach?.isEarned == true)
        #expect(AchievementsHub.badgePath("250336", locked: true) == "/Badge/250336_lock.png")
        #expect(PortCatalog.normalizedTitle("Pokemon - Ruby Version (USA, Europe) (Rev 2).zip") == PortCatalog.normalizedTitle("Pokemon Ruby Version"))
    }
}
