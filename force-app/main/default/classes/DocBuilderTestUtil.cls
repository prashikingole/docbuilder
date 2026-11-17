/** Shared helpers for DocBuilder tests. */
@IsTest
public class DocBuilderTestUtil {
    /** Gives the running user the DocBuilder Admin permission set, which includes the email and bulk permissions. */
    public static void grantAdmin() {
        Id userId = UserInfo.getUserId();
        PermissionSet adminSet = [SELECT Id FROM PermissionSet WHERE Name = 'DocBuilder_Admin'];
        if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :userId AND PermissionSetId = :adminSet.Id] == 0) {
            insert new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = adminSet.Id);
        }
    }

    /** A Standard User with only the given permission sets. */
    public static User standardUser(String alias, List<String> permissionSetNames) {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = alias + String.valueOf(Crypto.getRandomInteger()).replace('-', '') + '@docbuilder.test';
        User person = new User(
            Alias = alias.left(8),
            Email = alias + '@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Tester ' + alias,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = standard.Id,
            TimeZoneSidKey = 'Europe/London',
            Username = unique
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert person;
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSetNames]) {
                assignments.add(new PermissionSetAssignment(AssigneeId = person.Id, PermissionSetId = ps.Id));
            }
            insert assignments;
        }
        return person;
    }
}
