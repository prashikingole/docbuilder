/** Tests for the AppExchange security review fixes. */
@IsTest
private class DocBuilderSecurityTest {
    @TestSetup
    static void grantPermissions() {
        DocBuilderTestUtil.grantAdmin();
    }

    @IsTest
    static void richTextCleanerBlocksKnownBypasses() {
        Map<String, String> attacks = new Map<String, String>{
            'no space before handler' => '<img/src=x/onerror=alert(1)>',
            'entity-encoded scheme' => '<a href="jav&#97;script:alert(1)">x</a>',
            'svg handler' => '<svg><animate onbegin=alert(1) attributeName=x></svg>',
            'math element' => '<math><mi xlink:href="javascript:alert(1)">x</mi></math>',
            'css url' => '<p style="background:url(https://attacker.example/x)">x</p>',
            'css expression' => '<p style="width:expression(alert(1))">x</p>',
            'class injection' => '<p class="x&quot; onclick=&quot;alert(1)">x</p>',
            'script block' => '<script>alert(1)</script>',
            'handler on allowed tag' => '<p onmouseover="alert(1)">x</p>',
            'link' => '<a href="https://attacker.example">x</a>',
            'iframe' => '<iframe src="https://attacker.example"></iframe>',
            'comment' => '<!-- <script>alert(1)</script> -->'
        };
        for (String name : attacks.keySet()) {
            String out = DocBuilderContext.sanitize(attacks.get(name)).toLowerCase();
            System.assert(!out.contains('<img') && !out.contains('<a ') && !out.contains('<svg') && !out.contains('<math') && !out.contains('<iframe') && !out.contains('<script'), name + ': ' + out);
            System.assert(!out.contains('onerror') || out.contains('&'), name + ': ' + out);
            System.assert(!out.contains(' on') || !out.contains('="alert'), name + ': ' + out);
            System.assert(!out.contains('url(') && !out.contains('expression('), name + ': ' + out);
            System.assert(!out.contains('href'), name + ': ' + out);
        }

        // Ordinary formatting from the editor survives.
        String kept = DocBuilderContext.sanitize(
            '<p class="ql-align-center"><strong>Bold</strong> <em>it</em> <u>u</u><br><span style="color: rgb(230, 0, 0); font-size: 14px; position: fixed">red</span></p><ol><li>one</li></ol> 5 < 6 & AT&amp;T'
        );
        System.assertEquals(
            '<p class="ql-align-center"><strong>Bold</strong> <em>it</em> <u>u</u><br/><span style="color:rgb(230, 0, 0);font-size:14px">red</span></p><ol><li>one</li></ol> 5 &lt; 6 &amp; AT&amp;T',
            kept
        );
        System.assertEquals('', DocBuilderContext.sanitize(null));
    }

    @IsTest
    static void emailRulesAreEnforced() {
        System.assert(DocBuilderPolicy.canEmail(), 'The admin permission set includes email');
        System.assertEquals(new List<String>{ 'a@example.com' }, DocBuilderPolicy.checkRecipients(new List<String>{ ' A@Example.com ', '' }));
        assertRefused(new List<String>{ 'not-an-address' }, 'not a valid email');
        List<String> many = new List<String>();
        for (Integer i = 0; i < 11; i++) {
            many.add('p' + i + '@example.com');
        }
        assertRefused(many, 'at most 10');

        insert new DocBuilderSettings__c(SetupOwnerId = UserInfo.getOrganizationId(), Allowed_Email_Domains__c = 'example.com, @partner.org', Max_Email_Recipients__c = 2, Org_Wide_Email__c = 'nobody@example.invalid');
        DocBuilderPolicy.checkRecipients(new List<String>{ 'x@example.com', 'y@partner.org' });
        assertRefused(new List<String>{ 'x@attacker.example' }, 'only be emailed to these domains');
        assertRefused(new List<String>{ 'a@example.com', 'b@example.com', 'c@example.com' }, 'at most 2');
        System.assertEquals(null, DocBuilderPolicy.senderAddressId(), 'An address that is not a verified org-wide address is ignored');
    }

    static void assertRefused(List<String> recipients, String expected) {
        try {
            DocBuilderPolicy.checkRecipients(recipients);
            System.assert(false, 'Expected a refusal mentioning: ' + expected);
        } catch (DocBuilder.DocBuilderException e) {
            System.assert(e.getMessage().contains(expected), e.getMessage());
        }
    }

    @IsTest
    static void usersWithoutPermissionCannotEmailOrRunBulk() {
        Id templateId = DocBuilderSamples.createTemplate('Letter', 'Account', null, '{"blocks":[{"id":"a","type":"text","text":"For {{Name}}"}]}');
        User person = DocBuilderTestUtil.standardUser('dbuser', new List<String>{ 'DocBuilder_User' });
        System.runAs(person) {
            System.assert(!DocBuilderPolicy.canEmail());
            Account acct = new Account(Name = 'Own Account');
            insert acct;

            DocBuilder.Request req = new DocBuilder.Request();
            req.templateId = templateId;
            req.recordId = acct.Id;
            req.emailTo = new List<String>{ 'someone@example.com' };
            DocBuilder.Result res = DocBuilder.generate(req);
            System.assertEquals(false, res.success);
            System.assert(res.errorMessage.contains('permission to email'), res.errorMessage);
            System.assertEquals(null, res.contentVersionId, 'Nothing is generated when the email is refused');

            req.emailTo = null;
            res = DocBuilder.generate(req);
            System.assert(res.success, res.errorMessage);
            System.assertEquals(1, [SELECT COUNT() FROM GeneratedDocument__c WHERE Id = :res.documentId WITH USER_MODE], 'Users see their own generated documents');

            try {
                DocBuilder.generateInBackground('Letter', new List<Id>{ acct.Id });
                System.assert(false);
            } catch (DocBuilder.DocBuilderException e) {
                System.assert(e.getMessage().contains('bulk generation'), e.getMessage());
            }

            try {
                insert as user new GeneratedDocument__c(Status__c = 'Success');
                System.assert(false, 'Users cannot create audit records themselves');
            } catch (Exception e) {
                System.assert(true);
            }
            System.assertEquals(false, DocBuilderController.getSignOptions(templateId, acct.Id).canEmail);
        }
    }

    @IsTest
    static void bulkRunsAreCapped() {
        insert new DocBuilderSettings__c(SetupOwnerId = UserInfo.getOrganizationId(), Max_Bulk_Records__c = 2);
        Account acct = new Account(Name = 'A');
        insert acct;
        DocBuilderSamples.createTemplate('Letter', 'Account', null, '{"blocks":[]}');
        try {
            DocBuilder.generateInBackground('Letter', new List<Id>{ acct.Id, acct.Id, acct.Id });
            System.assert(false);
        } catch (DocBuilder.DocBuilderException e) {
            System.assert(e.getMessage().contains('at most 2'), e.getMessage());
        }
        try {
            DocBuilder.generateInBackground('Not A Template', new List<Id>{ acct.Id });
            System.assert(false);
        } catch (DocBuilder.DocBuilderException e) {
            System.assert(e.getMessage().contains('is available to you'), e.getMessage());
        }
    }

    @IsTest
    static void othersCannotSeeOrWithdrawARequest() {
        Account acct = new Account(Name = 'A');
        insert acct;
        DocSignRequest__c request = new DocSignRequest__c(Provider__c = 'TestProvider', External_Id__c = 'TEST-1', Status__c = 'Sent', Record_Id__c = acct.Id, File_Name__c = 'A.pdf');
        insert request;
        insert new GeneratedDocument__c(Status__c = 'Success', Snapshot_JSON__c = '{"values":{"AnnualRevenue":1000000}}');

        User person = DocBuilderTestUtil.standardUser('other', new List<String>{ 'DocBuilder_User' });
        System.runAs(person) {
            System.assertEquals(0, [SELECT COUNT() FROM GeneratedDocument__c WITH USER_MODE], 'Another user\'s snapshot is private');
            System.assertEquals(0, [SELECT COUNT() FROM DocSignRequest__c WITH USER_MODE], 'Another user\'s signature request is private');
            DocBuilderSign.refresh(request.Id);
            try {
                DocBuilderSign.cancel(request.Id, 'no');
                System.assert(false);
            } catch (DocBuilder.DocBuilderException e) {
                System.assert(e.getMessage().contains('do not have access'), e.getMessage());
            }
            try {
                DocBuilderController.withdrawSignature(request.Id, 'no');
                System.assert(false);
            } catch (AuraHandledException e) {
                System.assert(true);
            }
        }
        System.assertEquals('Sent', [SELECT Status__c FROM DocSignRequest__c WHERE Id = :request.Id].Status__c, 'Nothing was changed by the other user');
    }

    @IsTest
    static void providerReferencesAndErrorsAreHandledSafely() {
        System.assertEquals('ENV-1', DocBuilderSignHttp.pathId('ENV-1'));
        for (String bad : new List<String>{ '../accounts/other', 'a/b', 'a?b=c', 'a b', '', null }) {
            try {
                DocBuilderSignHttp.pathId(bad);
                System.assert(false, 'Expected "' + bad + '" to be refused');
            } catch (DocBuilder.DocBuilderException e) {
                System.assert(true);
            }
        }

        Exception unexpected = new MathException('Internal detail');
        System.assert(!DocBuilderSignHttp.userMessage(unexpected).contains('Internal detail'));
        System.assert(DocBuilderSignHttp.detailOf(unexpected).contains('Internal detail'));
        System.assertEquals('Plain', DocBuilderSignHttp.userMessage(new DocBuilder.DocBuilderException('Plain')));

        // A template that names a missing field fails with a plain message; the technical detail is kept for admins.
        Account acct = new Account(Name = 'A');
        insert acct;
        Id templateId = DocBuilderSamples.createTemplate('Broken', 'Account', null, '{"blocks":[{"type":"text","text":"{{Not_A_Field__c}}"}]}');
        DocBuilder.Request req = new DocBuilder.Request();
        req.templateId = templateId;
        req.recordId = acct.Id;
        DocBuilder.Result res = DocBuilder.generate(req);
        System.assertEquals(false, res.success);
        GeneratedDocument__c doc = [SELECT Error_Message__c, Error_Detail__c FROM GeneratedDocument__c WHERE Id = :res.documentId];
        // A template mistake is explained plainly to the user; the stack trace stays in the admin-only detail.
        System.assert(doc.Error_Message__c.contains('does not exist or that you cannot see'), doc.Error_Message__c);
        System.assert(!doc.Error_Message__c.contains('Class.'), doc.Error_Message__c);
        System.assert(doc.Error_Detail__c.contains('Class.DocBuilderContext'), doc.Error_Detail__c);
    }

    @IsTest
    static void noticesOnlyTriggerChecksForMatchingRequests() {
        Account acct = new Account(Name = 'A');
        insert acct;
        DocSignRequest__c mine = new DocSignRequest__c(Provider__c = 'DropboxSign', External_Id__c = 'SR-1', Status__c = 'Sent', Record_Id__c = acct.Id);
        DocSignRequest__c recent = new DocSignRequest__c(Provider__c = 'DropboxSign', External_Id__c = 'SR-2', Status__c = 'Sent', Record_Id__c = acct.Id, Last_Checked_On__c = System.now());
        insert new List<DocSignRequest__c>{ mine, recent };

        Test.startTest();
        DocBuilderSignNotices.handle(
            new List<DocSignNotice__e>{
                new DocSignNotice__e(Provider__c = 'DocuSign', External_Id__c = 'SR-1'),
                new DocSignNotice__e(Provider__c = 'DropboxSign', External_Id__c = 'SR-2'),
                new DocSignNotice__e(Provider__c = '', External_Id__c = 'SR-3')
            }
        );
        System.assertEquals(0, Limits.getQueueableJobs(), 'A wrong provider or a request checked seconds ago does not start a check');
        DocBuilderSignNotices.handle(new List<DocSignNotice__e>{ new DocSignNotice__e(Provider__c = 'DropboxSign', External_Id__c = 'SR-1') });
        System.assertEquals(1, Limits.getQueueableJobs());
        Test.stopTest();
    }
}
