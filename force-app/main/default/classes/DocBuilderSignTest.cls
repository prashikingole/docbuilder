@IsTest
private class DocBuilderSignTest {
    @TestSetup
    static void grantPermissions() {
        DocBuilderTestUtil.grantAdmin();
    }

    /** Answers provider calls by matching part of the URL. Records what was sent. */
    class Router implements HttpCalloutMock {
        Map<String, String> answers = new Map<String, String>();
        Integer statusCode = 200;
        List<String> seen = new List<String>();
        List<String> bodies = new List<String>();

        public HttpResponse respond(HttpRequest request) {
            seen.add(request.getMethod() + ' ' + request.getEndpoint());
            Blob body = request.getBodyAsBlob();
            bodies.add(body == null ? '' : body.toString());
            HttpResponse response = new HttpResponse();
            response.setStatusCode(statusCode);
            String answer = '{}';
            // Longest matching key wins, so /agreements/A1/members beats /agreements/A1.
            Integer best = -1;
            for (String key : answers.keySet()) {
                if ((request.getMethod() + ' ' + request.getEndpoint()).contains(key) && key.length() > best) {
                    best = key.length();
                    answer = answers.get(key);
                }
            }
            response.setBody(answer);
            return response;
        }
    }

    static DocBuilderSign.Envelope envelope(Map<String, Object> settings) {
        DocBuilderSign.ProviderConfig config = new DocBuilderSign.ProviderConfig();
        config.name = 'Unit';
        config.label = 'Unit provider';
        config.namedCredential = 'Unit_Credential';
        config.settings = settings;
        DocBuilderSign.Signer first = new DocBuilderSign.Signer();
        first.name = 'Priya Nair';
        first.email = 'priya@example.com';
        first.role = 'Customer';
        first.routingOrder = 1;
        DocBuilderSign.Signer second = new DocBuilderSign.Signer();
        second.email = 'sam@example.com';
        DocBuilderSign.Envelope envelope = new DocBuilderSign.Envelope();
        envelope.config = config;
        envelope.fileName = 'Quote.pdf';
        envelope.file = Blob.valueOf('PDF-BYTES');
        envelope.subject = 'Please sign';
        envelope.message = 'Thanks';
        envelope.signers = new List<DocBuilderSign.Signer>{ first, second };
        return envelope;
    }

    static Opportunity makeOpportunity() {
        Account acct = new Account(Name = 'Harbor Sample Co');
        insert acct;
        Opportunity opp = new Opportunity(AccountId = acct.Id, Name = 'Deal B', StageName = 'Prospecting', CloseDate = Date.today().addDays(30), Amount = 3000);
        insert opp;
        return opp;
    }

    static Id makeTemplate(String name, Boolean withSigners) {
        Map<String, Object> body = new Map<String, Object>{
            'blocks' => new List<Object>{
                new Map<String, Object>{ 'id' => 'a', 'type' => 'text', 'text' => 'Agreement for {{Name}}' },
                new Map<String, Object>{ 'id' => 's', 'type' => 'signature', 'showName' => true }
            }
        };
        if (withSigners) {
            body.put(
                'signers',
                new List<Object>{
                    new Map<String, Object>{ 'role' => 'Customer', 'name' => '{{Account.Name}}', 'email' => 'buyer@example.com' },
                    new Map<String, Object>{ 'name' => '{{Owner.Name}}', 'email' => '{{Owner.Email}}' }
                }
            );
        }
        return DocBuilderSamples.createTemplate(name, 'Opportunity', 'Agreement {{Name}}', JSON.serialize(body));
    }

    static String fileText(Id contentVersionId) {
        return [SELECT VersionData FROM ContentVersion WHERE Id = :contentVersionId].VersionData.toString();
    }

    @IsTest
    static void fullLoopWithTheTestProvider() {
        Opportunity opp = makeOpportunity();
        Id templateId = makeTemplate('Agreement', true);

        DocBuilderController.SignOptions options = DocBuilderController.getSignOptions(templateId, opp.Id);
        Boolean hasTestProvider = false;
        for (DocBuilderSign.ProviderOption option : options.providers) {
            hasTestProvider = hasTestProvider || option.name == 'TestProvider';
        }
        System.assert(hasTestProvider, 'The test provider is offered (in tests it always counts as switched on)');

        // A provider that is switched off is neither offered nor usable for new requests.
        DocBuilderSign.testInactive.add('TestProvider');
        for (DocBuilderSign.ProviderOption option : DocBuilderController.getSignOptions(templateId, opp.Id).providers) {
            System.assertNotEquals('TestProvider', option.name);
        }
        try {
            DocBuilderController.sendForSignature(new List<Id>{ templateId }, opp.Id, null, 'TestProvider', null, null, 'x');
            System.assert(false, 'A switched-off provider must be refused');
        } catch (Exception e) {
            System.assert(true);
        }
        DocBuilderSign.testInactive.clear();
        System.assertEquals(2, options.signers.size());
        System.assertEquals('Harbor Sample Co', options.signers[0].name);
        System.assertEquals('Customer', options.signers[0].role);
        System.assertEquals('Signer 2', options.signers[1].role);
        System.assertEquals(UserInfo.getUserEmail(), options.signers[1].email);

        Test.startTest();
        Id requestId = DocBuilderController.sendForSignature(new List<Id>{ templateId }, opp.Id, null, 'TestProvider', null, null, 'Please sign this');
        Test.stopTest();

        DocSignRequest__c request = [
            SELECT Status__c, External_Id__c, Subject__c, Unsigned_Content_Version_Id__c, Generated_Document__c, (SELECT Status__c, Email__c, Routing_Order__c FROM Signers__r ORDER BY Routing_Order__c)
            FROM DocSignRequest__c
            WHERE Id = :requestId
        ];
        System.assertEquals('Sent', request.Status__c);
        System.assert(request.External_Id__c.startsWith('TEST-'));
        System.assertEquals('Please sign: Agreement Deal B', request.Subject__c);
        System.assertNotEquals(null, request.Generated_Document__c);
        System.assertEquals(2, request.Signers__r.size());
        System.assertEquals('Sent', request.Signers__r[0].Status__c);
        System.assertEquals('buyer@example.com', request.Signers__r[0].Email__c);
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :opp.Id], 'The unsigned copy is not attached to the record');

        String html = fileText(request.Unsigned_Content_Version_Id__c);
        System.assert(html.contains('class="sigline"') && html.contains('Customer, Harbor Sample Co'), html);
        System.assert(!html.contains('class="mk"'), 'The test provider prints no hidden markers');

        DocBuilderController.SignatureView refreshed = DocBuilderController.refreshSignature(requestId);
        System.assertEquals('Completed', refreshed.request.Status__c);
        System.assertNotEquals(null, refreshed.signedDocumentId);
        System.assertEquals('Signed', refreshed.signers[0].Status__c);
        System.assertEquals('Signed', refreshed.signers[1].Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :opp.Id], 'The signed copy is attached to the record');
        System.assertEquals('Agreement Deal B - signed', [SELECT Title FROM ContentVersion WHERE Id = :refreshed.request.Signed_Content_Version_Id__c].Title);

        // The background sync picks up requests that are still out for signature.
        update new DocSignRequest__c(Id = requestId, Status__c = 'Sent');
        new DocBuilderSignSyncJob(null).execute(null);
        System.assertEquals('Completed', [SELECT Status__c FROM DocSignRequest__c WHERE Id = :requestId].Status__c);
        new DocBuilderSignSyncJob(null).execute(null);
        new DocBuilderSignSync().execute((SchedulableContext) null);
        System.assert(!DocBuilderSignSync.isScheduled());

        DocBuilderSign.cancel(requestId, null);
        System.assertEquals('Voided', [SELECT Status__c FROM DocSignRequest__c WHERE Id = :requestId].Status__c);

        DocBuilderSignSync.schedule();
        System.assertEquals(4, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'DocBuilder signature status%']);
        DocBuilderSignSync.unschedule();
        System.assertEquals(0, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'DocBuilder signature status%']);
    }

    @IsTest
    static void signersComeFromRecordsAndListsAndEmptyRowsAreIgnored() {
        Opportunity opp = makeOpportunity();
        List<Contact> people = new List<Contact>{
            new Contact(AccountId = opp.AccountId, FirstName = 'Priya', LastName = 'Nair', Email = 'priya@example.com'),
            new Contact(AccountId = opp.AccountId, FirstName = 'No', LastName = 'Email'),
            new Contact(AccountId = opp.AccountId, FirstName = 'Ivan', LastName = 'Influencer', Email = 'ivan@example.com')
        };
        insert people;
        insert new List<OpportunityContactRole>{
            new OpportunityContactRole(OpportunityId = opp.Id, ContactId = people[0].Id, Role = 'Decision Maker'),
            new OpportunityContactRole(OpportunityId = opp.Id, ContactId = people[1].Id, Role = 'Decision Maker'),
            new OpportunityContactRole(OpportunityId = opp.Id, ContactId = people[2].Id, Role = 'Influencer')
        };
        Map<String, Object> body = new Map<String, Object>{
            'signers' => new List<Object>{
                new Map<String, Object>{
                    'role' => 'Customer',
                    'source' => 'OpportunityContactRoles',
                    'nameField' => 'Contact.Name',
                    'emailField' => 'Contact.Email',
                    'filter' => new Map<String, Object>{ 'conditions' => new List<Object>{ new Map<String, Object>{ 'field' => 'Role', 'op' => 'ne', 'value' => 'Influencer' } } }
                },
                new Map<String, Object>{ 'role' => 'Company', 'name' => '{{Owner.Name}}', 'email' => '{{Owner.Email}}' },
                new Map<String, Object>{ 'role' => '', 'name' => '', 'email' => '' }
            },
            'blocks' => new List<Object>{ new Map<String, Object>{ 'id' => 's', 'type' => 'signature' } }
        };
        // The template's own object name as a prefix is accepted, as SOQL allows.
        Id templateId = DocBuilderSamples.createTemplate('From Records', 'Opportunity', '{{Opportunity.Name}} - {{Account.Name}}', JSON.serialize(body));

        List<DocBuilderSign.Signer> signers = DocBuilderController.getSignOptions(templateId, opp.Id).signers;
        System.assertEquals(2, signers.size(), 'Priya from the list, the owner, and nobody for the empty row, the influencer or the contact without email');
        System.assertEquals('Priya Nair', signers[0].name);
        System.assertEquals('priya@example.com', signers[0].email);
        System.assertEquals('Customer', signers[0].role);
        System.assertEquals('Company', signers[1].role);
        System.assertEquals(UserInfo.getUserEmail(), signers[1].email);

        DocBuilder.Request req = new DocBuilder.Request();
        req.templateId = templateId;
        req.recordId = opp.Id;
        DocBuilder.Result res = DocBuilder.generate(req);
        System.assert(res.success, res.errorMessage);
        System.assertEquals('Deal B - Harbor Sample Co.pdf', res.fileName);
        System.assert(fileText(res.contentVersionId).contains('Customer, Priya Nair'));

        // A wrong field name is explained instead of a generic failure.
        Id wrongId = DocBuilderSamples.createTemplate('Wrong', 'Opportunity', '{{Name}}', '{"blocks":[{"id":"a","type":"text","text":"{{Quote.Name}}"}]}');
        req.templateId = wrongId;
        res = DocBuilder.generate(req);
        System.assertEquals(false, res.success);
        System.assert(res.errorMessage.contains('Quote'), res.errorMessage);
        System.assert(!res.errorMessage.contains('Something went wrong'), res.errorMessage);
    }

    @IsTest
    static void templateWordingAndConnectionTests() {
        Opportunity opp = makeOpportunity();
        Map<String, Object> body = new Map<String, Object>{
            'messages' => new Map<String, Object>{
                'emailSubject' => 'Your quote for {{Name}}',
                'emailBody' => 'Hello {{Account.Name}},\nyour quote is attached.',
                'signSubject' => 'Please sign {{Name}}',
                'signMessage' => '{{#if Amount}}Total {{Amount}}{{/if}}'
            },
            'signers' => new List<Object>{ new Map<String, Object>{ 'role' => 'Customer', 'name' => 'Pat', 'email' => 'pat@example.com' } },
            'blocks' => new List<Object>{ new Map<String, Object>{ 'id' => 's', 'type' => 'signature' } }
        };
        Id templateId = DocBuilderSamples.createTemplate('Worded', 'Opportunity', null, JSON.serialize(body));

        DocBuilderController.SignOptions options = DocBuilderController.getSignOptions(templateId, opp.Id);
        System.assertEquals('Your quote for Deal B', options.emailSubject);
        System.assertEquals('Hello Harbor Sample Co,\nyour quote is attached.', options.emailBody);
        System.assertEquals('Please sign Deal B', options.signSubject);
        System.assert(options.signMessage.startsWith('Total '), options.signMessage);

        DocBuilder.Request req = new DocBuilder.Request();
        req.templateId = templateId;
        req.recordId = opp.Id;
        req.emailTo = new List<String>{ 'someone@example.com' };
        DocBuilder.Result res = DocBuilder.generate(req);
        System.assert(res.success, res.errorMessage);
        System.assertEquals('Your quote for Deal B', req.emailSubject, 'The template subject is used when the sender leaves it blank');
        System.assertEquals('Please sign Deal B', res.signSubject);

        Test.startTest();
        DocBuilderSign.SendRequest send = new DocBuilderSign.SendRequest();
        send.templateId = templateId;
        send.recordId = opp.Id;
        send.providerName = 'TestProvider';
        Id requestId = DocBuilderSign.send(send);
        Test.stopTest();
        DocSignRequest__c sent = [SELECT Subject__c, Message__c FROM DocSignRequest__c WHERE Id = :requestId];
        System.assertEquals('Please sign Deal B', sent.Subject__c);
        System.assert(sent.Message__c.startsWith('Total '));

        // Connection tests
        Router router = new Router();
        router.answers.put('GET callout:Unit_Credential/v3/account', '{"account":{"email_address":"me@example.com"}}');
        router.answers.put('GET callout:Unit_Credential/restapi/v2.1/accounts/ACC1', '{"accountName":"Acme"}');
        router.answers.put('GET callout:Unit_Credential/api/rest/v6/users/me', '{"email":"admin@example.com"}');
        Test.setMock(HttpCalloutMock.class, router);
        DocBuilderSign.testSettings.put('DropboxSign', new Map<String, Object>{ 'testMode' => true });
        DocBuilderSign.testSettings.put('DocuSign', new Map<String, Object>{ 'accountId' => 'ACC1' });
        DocBuilderSign.testSettings.put('AdobeSign', new Map<String, Object>());
        DocBuilderDesignerController.ConnectionResult ok = DocBuilderDesignerController.testProvider('DropboxSign');
        System.assert(ok.ok && ok.message.contains('me@example.com') && ok.message.contains('Test mode'), ok.message);
        System.assert(DocBuilderDesignerController.testProvider('DocuSign').message.contains('Acme'));
        System.assert(DocBuilderDesignerController.testProvider('AdobeSign').message.contains('admin@example.com'));
        System.assert(DocBuilderDesignerController.testProvider('TestProvider').message.contains('no connection test'));
        DocBuilderDesignerController.ConnectionResult missing = DocBuilderDesignerController.testProvider('Not_A_Provider');
        System.assertEquals(false, missing.ok);
        router.statusCode = 401;
        DocBuilderDesignerController.ConnectionResult refused = DocBuilderDesignerController.testProvider('DropboxSign');
        System.assertEquals(false, refused.ok);
        System.assert(refused.message.contains('HTTP 401'), refused.message);
        System.assert(DocBuilderDesignerController.listProviders().size() >= 4);
    }

    @IsTest
    static void manySignersTrackerViewAndWithdraw() {
        Opportunity opp = makeOpportunity();
        List<Object> five = new List<Object>();
        for (Integer i = 1; i <= 5; i++) {
            five.add(new Map<String, Object>{ 'role' => 'Party ' + i, 'name' => 'Person ' + i, 'email' => 'p' + i + '@example.com' });
        }
        String body = JSON.serialize(new Map<String, Object>{ 'signers' => five, 'blocks' => new List<Object>{ new Map<String, Object>{ 'id' => 's', 'type' => 'signature' } } });
        Id templateId = DocBuilderSamples.createTemplate('Five Party', 'Opportunity', null, body);

        // Five signers print as two rows of three areas, the last one padded.
        DocBuilder.Request gen = new DocBuilder.Request();
        gen.templateId = templateId;
        gen.recordId = opp.Id;
        gen.signProviderName = 'DocuSign';
        String html = fileText(DocBuilder.generate(gen).contentVersionId);
        System.assertEquals(2, html.countMatches('<tr>'), html);
        System.assertEquals(5, html.countMatches('class="sigline"'));
        System.assert(html.contains('/dssig5/') && html.contains('Party 5, Person 5'));
        System.assert(html.contains('<td class="s5" style="width:33%">') && html.contains('<td style="width:33%"></td>'));

        // Sent to everyone at once: every signer shares position 1.
        List<Object> together = new List<Object>();
        for (Integer i = 1; i <= 5; i++) {
            together.add(new Map<String, Object>{ 'role' => 'Party ' + i, 'name' => 'Person ' + i, 'email' => 'p' + i + '@example.com', 'routingOrder' => 1 });
        }
        Test.startTest();
        Id requestId = DocBuilderController.sendForSignature(new List<Id>{ templateId }, opp.Id, null, 'TestProvider', JSON.serialize(together), 'Five party deal', null);
        Test.stopTest();

        DocBuilderController.SignatureView view = DocBuilderController.getSignatureView(requestId);
        System.assertEquals('Sent', view.request.Status__c);
        System.assertEquals(5, view.signers.size());
        System.assertEquals(1, view.signers[4].Routing_Order__c);
        System.assertEquals('Test provider (nothing is sent)', view.providerLabel);
        System.assertEquals('Five Party', view.templateName);
        System.assertNotEquals(null, view.sentDocumentId);
        System.assertEquals(null, view.signedDocumentId);
        System.assertNotEquals(null, view.sentBy);

        view = DocBuilderController.withdrawSignature(requestId, 'No longer needed');
        System.assertEquals('Voided', view.request.Status__c);

        for (DocBuilderSign.ProviderOption option : DocBuilderSign.activeProviders()) {
            System.assert(new Set<String>{ 'form', 'steps', 'desk' }.contains(option.style));
        }
    }

    @IsTest
    static void signerOverridesFlowActionAndValidation() {
        Opportunity opp = makeOpportunity();
        Id templateId = makeTemplate('Agreement', true);
        Id noSigners = makeTemplate('No Signers', false);

        DocBuilderSignFlowAction.Input input = new DocBuilderSignFlowAction.Input();
        input.templateName = 'Agreement';
        input.recordId = opp.Id;
        input.providerName = 'TestProvider';
        input.signerEmails = 'one@example.com; two@example.com';
        input.subject = 'Custom subject';
        DocBuilderSignFlowAction.Input missing = new DocBuilderSignFlowAction.Input();
        missing.templateName = 'Nothing';
        missing.recordId = opp.Id;
        missing.providerName = 'TestProvider';

        Test.startTest();
        List<DocBuilderSignFlowAction.Output> outputs = DocBuilderSignFlowAction.send(new List<DocBuilderSignFlowAction.Input>{ input, missing });
        Test.stopTest();

        System.assert(outputs[0].success, outputs[0].errorMessage);
        DocSignRequest__c request = [SELECT Subject__c, (SELECT Email__c FROM Signers__r ORDER BY Routing_Order__c) FROM DocSignRequest__c WHERE Id = :outputs[0].signatureRequestId];
        System.assertEquals('Custom subject', request.Subject__c);
        System.assertEquals('two@example.com', request.Signers__r[1].Email__c);
        System.assertEquals(false, outputs[1].success);
        System.assert(outputs[1].errorMessage.contains('No active template'));

        String signersJson = JSON.serialize(new List<Object>{ new Map<String, Object>{ 'role' => 'Customer', 'name' => 'Someone', 'email' => '' } });
        for (List<String> attempt : new List<List<String>>{
            new List<String>{ String.valueOf(noSigners), 'TestProvider', null, 'has no signers' },
            new List<String>{ String.valueOf(templateId), 'TestProvider', signersJson, 'has no email' },
            new List<String>{ String.valueOf(templateId), 'Not_A_Provider', null, 'no signature provider' },
            new List<String>{ String.valueOf(templateId), null, null, 'are required' }
        }) {
            try {
                DocBuilderSign.SendRequest bad = new DocBuilderSign.SendRequest();
                bad.templateId = attempt[0];
                bad.recordId = opp.Id;
                bad.providerName = attempt[1];
                if (attempt[2] != null) {
                    bad.signers = (List<DocBuilderSign.Signer>) JSON.deserialize(attempt[2], List<DocBuilderSign.Signer>.class);
                }
                DocBuilderSign.send(bad);
                System.assert(false, 'Expected a failure mentioning: ' + attempt[3]);
            } catch (DocBuilder.DocBuilderException e) {
                System.assert(e.getMessage().contains(attempt[3]), e.getMessage());
            }
        }
        try {
            DocBuilderController.sendForSignature(new List<Id>{ templateId }, opp.Id, null, 'Not_A_Provider', null, null, null);
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        System.assertEquals(0, DocBuilderController.getSignOptions(noSigners, opp.Id).signers.size());
    }

    @IsTest
    static void markersArePrintedForRealProviders() {
        Opportunity opp = makeOpportunity();
        Id templateId = makeTemplate('Agreement', true);

        DocBuilder.Request req = new DocBuilder.Request();
        req.templateId = templateId;
        req.recordId = opp.Id;
        req.signProviderName = 'DocuSign';
        DocBuilder.Result res = DocBuilder.generate(req);
        System.assert(res.success, res.errorMessage);
        String html = fileText(res.contentVersionId);
        System.assert(html.contains('<span class="mk">/dssig1/</span>') && html.contains('/dsdate2/') && html.contains('/dsname1/'), html);
        System.assertEquals(2, res.signers.size());

        req.signProviderName = 'AdobeSign';
        html = fileText(DocBuilder.generate(req).contentVersionId);
        System.assert(html.contains('{{Sig_es_:signer1:signature}}') && html.contains('{{Dte_es_:signer2:date}}'), html);

        req.signProviderName = 'DropboxSign';
        html = fileText(DocBuilder.generate(req).contentVersionId);
        System.assert(html.contains('[sig|req|signer1]') && html.contains('[date|req|signer2]'), html);

        req.signProviderName = null;
        html = fileText(DocBuilder.generate(req).contentVersionId);
        System.assert(html.contains('class="sigline"') && !html.contains('class="mk"'), 'A plain document has signature lines and no markers');

        System.assertEquals('{{Int_es_:signer3:initials}}', new DocBuilderSignAdobe().marker(3, 'initials'));
        System.assertEquals('{{Name_es_:signer1:fullname}}', new DocBuilderSignAdobe().marker(1, 'name'));
        System.assertEquals('[initial|req|signer2]', new DocBuilderSignDropbox().marker(2, 'initials'));
        System.assertEquals('[text|req|signer1|Full name]', new DocBuilderSignDropbox().marker(1, 'name'));
        System.assertEquals('/dsinit4/', new DocBuilderSignDocuSign().marker(4, 'initials'));
    }

    @IsTest
    static void docuSignCalls() {
        Router router = new Router();
        router.answers.put('POST callout:Unit_Credential/restapi/v2.1/accounts/ACC1/envelopes', '{"envelopeId":"ENV-1","status":"sent"}');
        router.answers.put(
            'GET callout:Unit_Credential/restapi/v2.1/accounts/ACC1/envelopes/ENV-1',
            '{"status":"completed","recipients":{"signers":[{"email":"priya@example.com","status":"completed","signedDateTime":"2026-11-16T10:00:00.000Z"},{"email":"sam@example.com","status":"declined"}]}}'
        );
        Test.setMock(HttpCalloutMock.class, router);
        DocBuilderSign.Envelope env = envelope(new Map<String, Object>{ 'accountId' => 'ACC1' });
        DocBuilderSignDocuSign provider = new DocBuilderSignDocuSign();

        Test.startTest();
        System.assertEquals('ENV-1', provider.send(env).externalId);
        System.assert(router.bodies[0].contains('"anchorString":"/dssig1/"') && router.bodies[0].contains('"documentBase64"') && router.bodies[0].contains('"routingOrder":"2"'), router.bodies[0]);

        DocBuilderSign.StatusResult status = provider.getStatus(env.config, 'ENV-1');
        System.assertEquals('Completed', status.status);
        System.assertEquals('Signed', status.signers[0].status);
        System.assertNotEquals(null, status.signers[0].signedOn);
        System.assertEquals('Declined', status.signers[1].status);

        System.assertNotEquals(null, provider.download(env.config, 'ENV-1'));
        provider.cancel(env.config, 'ENV-1', 'Changed');
        System.assert(router.seen[router.seen.size() - 1].startsWith('PUT'));
        System.assert(router.bodies[router.bodies.size() - 1].contains('voided'));

        try {
            provider.getStatus(envelope(new Map<String, Object>()).config, 'ENV-1');
            System.assert(false);
        } catch (DocBuilder.DocBuilderException e) {
            System.assert(e.getMessage().contains('account ID'));
        }
        router.statusCode = 401;
        try {
            provider.getStatus(env.config, 'ENV-1');
            System.assert(false);
        } catch (DocBuilderSignHttp.ProviderException e) {
            System.assert(e.getMessage().contains('HTTP 401'), e.getMessage());
            System.assertNotEquals(null, e.detail, 'The provider response is kept for administrators');
            System.assert(!e.getMessage().contains(e.detail), 'The provider response is not in the user-facing message');
        }
        env.config.namedCredential = null;
        try {
            provider.getStatus(env.config, 'ENV-1');
            System.assert(false);
        } catch (DocBuilder.DocBuilderException e) {
            System.assert(e.getMessage().contains('no Named Credential'));
        }
        Test.stopTest();
    }

    @IsTest
    static void adobeSignCalls() {
        Router router = new Router();
        router.answers.put('POST callout:Unit_Credential/api/rest/v6/transientDocuments', '{"transientDocumentId":"TD-1"}');
        router.answers.put('POST callout:Unit_Credential/api/rest/v6/agreements', '{"id":"AG-1"}');
        router.answers.put('GET callout:Unit_Credential/api/rest/v6/agreements/AG-1', '{"id":"AG-1","status":"OUT_FOR_SIGNATURE"}');
        router.answers.put(
            'GET callout:Unit_Credential/api/rest/v6/agreements/AG-1/members',
            '{"participantSets":[{"status":"COMPLETED","memberInfos":[{"email":"priya@example.com"}]},{"status":"WAITING_FOR_MY_SIGNATURE","memberInfos":[{"email":"sam@example.com","status":"ACTIVE"}]}]}'
        );
        router.answers.put('GET callout:Unit_Credential/api/rest/v6/agreements/AG-2', '{"id":"AG-2","status":"SIGNED"}');
        router.answers.put('GET callout:Unit_Credential/api/rest/v6/agreements/AG-3', '{"id":"AG-3","status":"CANCELLED"}');
        router.answers.put('GET callout:Unit_Credential/api/rest/v6/agreements/AG-3/members', '{"participantSets":[{"memberInfos":[{"email":"sam@example.com","status":"DECLINED"}]}]}');
        Test.setMock(HttpCalloutMock.class, router);
        DocBuilderSign.Envelope env = envelope(new Map<String, Object>());
        DocBuilderSignAdobe provider = new DocBuilderSignAdobe();

        Test.startTest();
        System.assertEquals('AG-1', provider.send(env).externalId);
        System.assert(router.bodies[0].contains('name="File"; filename="Quote.pdf"') && router.bodies[0].contains('PDF-BYTES'), 'The upload is multipart with the file inside');
        System.assert(router.bodies[1].contains('"transientDocumentId":"TD-1"') && router.bodies[1].contains('"state":"IN_PROCESS"'), router.bodies[1]);

        DocBuilderSign.StatusResult status = provider.getStatus(env.config, 'AG-1');
        System.assertEquals('Sent', status.status);
        System.assertEquals('Signed', status.signers[0].status);
        System.assertEquals('Sent', status.signers[1].status);
        System.assertEquals('Completed', provider.getStatus(env.config, 'AG-2').status);
        status = provider.getStatus(env.config, 'AG-3');
        System.assertEquals('Declined', status.status);
        System.assertEquals('Declined', status.signers[0].status);

        System.assertNotEquals(null, provider.download(env.config, 'AG-1'));
        provider.cancel(env.config, 'AG-1', 'Changed');
        System.assert(router.seen[router.seen.size() - 1].endsWith('/agreements/AG-1/state'));
        Test.stopTest();
    }

    @IsTest
    static void dropboxSignCalls() {
        Router router = new Router();
        router.answers.put('POST callout:Unit_Credential/v3/signature_request/send', '{"signature_request":{"signature_request_id":"SR-1"}}');
        router.answers.put(
            'GET callout:Unit_Credential/v3/signature_request/SR-1',
            '{"signature_request":{"is_complete":false,"is_declined":false,"signatures":[{"signer_email_address":"priya@example.com","status_code":"signed","signed_at":1794830400},{"signer_email_address":"sam@example.com","status_code":"awaiting_signature"}]}}'
        );
        router.answers.put('GET callout:Unit_Credential/v3/signature_request/SR-2', '{"signature_request":{"is_complete":true,"signatures":[]}}');
        router.answers.put('GET callout:Unit_Credential/v3/signature_request/SR-3', '{"signature_request":{"is_declined":true,"signatures":[{"signer_email_address":"sam@example.com","status_code":"declined"}]}}');
        Test.setMock(HttpCalloutMock.class, router);
        DocBuilderSign.Envelope env = envelope(new Map<String, Object>{ 'testMode' => true });
        DocBuilderSignDropbox provider = new DocBuilderSignDropbox();

        Test.startTest();
        System.assertEquals('SR-1', provider.send(env).externalId);
        String sent = router.bodies[0];
        System.assert(sent.contains('name="use_text_tags"') && sent.contains('name="test_mode"') && sent.contains('name="signers[1][email_address]"') && sent.contains('name="files[0]"; filename="Quote.pdf"'), sent);

        DocBuilderSign.StatusResult status = provider.getStatus(env.config, 'SR-1');
        System.assertEquals('Sent', status.status);
        System.assertEquals('Signed', status.signers[0].status);
        System.assertNotEquals(null, status.signers[0].signedOn);
        System.assertEquals('Sent', status.signers[1].status);
        System.assertEquals('Completed', provider.getStatus(env.config, 'SR-2').status);
        System.assertEquals('Declined', provider.getStatus(env.config, 'SR-3').status);

        System.assertNotEquals(null, provider.download(env.config, 'SR-1'));
        provider.cancel(env.config, 'SR-1', 'Changed');
        System.assert(router.seen[router.seen.size() - 1].contains('/v3/signature_request/cancel/SR-1'));

        // Dropbox Sign leaves the order out when everyone signs at once.
        System.assert(sent.contains('[order]'), 'Signers in sequence carry an order');
        env.signers[0].routingOrder = 1;
        env.signers[1].routingOrder = 1;
        provider.send(env);
        System.assert(!router.bodies[router.bodies.size() - 1].contains('[order]'), 'No order means everyone at once');
        Test.stopTest();
    }

    static RestResponse callWebhook(String method, String providerName, String token, String body, Map<String, String> headers) {
        RestRequest request = new RestRequest();
        request.httpMethod = method;
        request.requestURI = '/docbuilder/sign/' + providerName;
        if (token != null) {
            request.params.put('token', token);
        }
        if (body != null) {
            request.requestBody = Blob.valueOf(body);
        }
        if (headers != null) {
            request.headers.putAll(headers);
        }
        RestContext.request = request;
        RestContext.response = new RestResponse();
        if (method == 'GET') {
            DocBuilderSignWebhookEndpoint.verify();
        } else {
            DocBuilderSignWebhookEndpoint.receive();
        }
        return RestContext.response;
    }

    @IsTest
    static void webhookTriggersAnImmediateStatusCheck() {
        Opportunity opp = makeOpportunity();
        DocBuilderSign.testSettings.put('DropboxSign', new Map<String, Object>());
        DocBuilderSign.testSettings.put('DocuSign', new Map<String, Object>{ 'accountId' => 'ACC1' });
        List<DocSignSecret__c> secrets = new List<DocSignSecret__c>();
        for (String provider : new List<String>{ 'DropboxSign', 'AdobeSign', 'DocuSign', 'TestProvider' }) {
            secrets.add(new DocSignSecret__c(Name = provider, Webhook_Secret__c = 'S3cret'));
        }
        insert secrets;

        DocSignRequest__c request = new DocSignRequest__c(Provider__c = 'DropboxSign', External_Id__c = 'SR-9', Status__c = 'Sent', Record_Id__c = opp.Id, File_Name__c = 'Quote.pdf');
        insert request;
        insert new DocSigner__c(Sign_Request__c = request.Id, Email__c = 'priya@example.com', Status__c = 'Sent', Routing_Order__c = 1);

        Router router = new Router();
        router.answers.put('GET callout:Unit_Credential/v3/signature_request/SR-9', '{"signature_request":{"is_complete":true,"signatures":[{"signer_email_address":"priya@example.com","status_code":"signed"}]}}');
        router.answers.put('GET callout:Unit_Credential/v3/signature_request/files/SR-9', 'SIGNED-PDF');
        Test.setMock(HttpCalloutMock.class, router);

        // Wrong or missing token, unknown provider, and a provider with no webhook support are all refused.
        System.assertEquals(401, callWebhook('POST', 'DropboxSign', 'wrong', '{}', null).statusCode);
        System.assertEquals(401, callWebhook('POST', 'DropboxSign', 's3cret', '{}', null).statusCode, 'The token is case-sensitive');
        System.assertEquals(401, callWebhook('POST', 'DropboxSign', null, '{}', null).statusCode);
        // Every rejection looks the same to the caller.
        System.assertEquals(401, callWebhook('POST', 'Not_A_Provider', 'S3cret', '{}', null).statusCode);
        System.assertEquals(401, callWebhook('POST', 'TestProvider', 'S3cret', '{}', null).statusCode, 'A provider without notification support is refused the same way');
        System.assertEquals(401, callWebhook('POST', 'A_Provider_Name_That_Is_Far_Too_Long_For_A_Setting', 'S3cret', '{}', null).statusCode);
        System.assertEquals(null, RestContext.response.responseBody, 'A rejection carries no detail');
        System.assert(!DocBuilderSignWebhookEndpoint.authorised('DropboxSign', ''));
        System.assert(DocBuilderSignWebhookEndpoint.authorised('DropboxSign', 'S3cret'));

        Test.startTest();
        RestResponse response = callWebhook('POST', 'DropboxSign', 'S3cret', '{"event":{"event_type":"signature_request_all_signed"},"signature_request":{"signature_request_id":"SR-9"}}', null);
        // The endpoint only raises an event; the handler then checks the provider in the background.
        System.assertEquals('Sent', [SELECT Status__c FROM DocSignRequest__c WHERE Id = :request.Id].Status__c, 'Nothing is changed by the notification itself');
        Test.getEventBus().deliver();
        Test.stopTest();

        System.assertEquals(200, response.statusCode, 'Endpoint error: ' + DocBuilderSignWebhookEndpoint.lastError);
        System.assertEquals('Hello API Event Received', response.responseBody.toString());
        DocSignRequest__c after = [SELECT Status__c, Signed_Content_Version_Id__c FROM DocSignRequest__c WHERE Id = :request.Id];
        System.assertEquals('Completed', after.Status__c, 'The notification triggered a real status check with the provider');
        System.assertEquals('SIGNED-PDF', fileText(after.Signed_Content_Version_Id__c));
        System.assertEquals('Signed', [SELECT Status__c FROM DocSigner__c WHERE Sign_Request__c = :request.Id].Status__c);

        // Acrobat Sign checks the address with a GET and expects its client ID echoed back.
        response = callWebhook('GET', 'AdobeSign', 'S3cret', null, new Map<String, String>{ 'X-AdobeSign-ClientId' => 'CLIENT-1' });
        System.assertEquals(200, response.statusCode);
        System.assert(response.responseBody.toString().contains('CLIENT-1'));
        response = callWebhook('POST', 'AdobeSign', 'S3cret', '{"event":"AGREEMENT_WORKFLOW_COMPLETED","agreement":{"id":"AG-404"}}', null);
        System.assertEquals(200, response.statusCode);

        // DocuSign Connect, in both shapes it can send.
        RestRequest connect = new RestRequest();
        connect.requestBody = Blob.valueOf('{"event":"envelope-completed","data":{"envelopeId":"ENV-7"}}');
        System.assertEquals('ENV-7', new DocBuilderSignDocuSign().externalIdOf(connect));
        connect.requestBody = Blob.valueOf('{"envelopeId":"ENV-8"}');
        System.assertEquals('ENV-8', new DocBuilderSignDocuSign().externalIdOf(connect));
        System.assertEquals(null, new DocBuilderSignDocuSign().externalIdOf(new RestRequest()));
        System.assertEquals(200, callWebhook('POST', 'DocuSign', 'S3cret', '{"data":{"envelopeId":"ENV-404"}}', null).statusCode);
        System.assertEquals(null, new DocBuilderSignDropbox().externalIdOf(new RestRequest()));
    }

    @IsTest
    static void providerStatusIsAppliedToRequestsAndSigners() {
        Opportunity opp = makeOpportunity();
        ContentVersion unsignedFile = new ContentVersion(Title = 'Quote', PathOnClient = 'Quote.pdf', VersionData = Blob.valueOf('UNSIGNED'));
        insert unsignedFile;
        DocSignRequest__c request = new DocSignRequest__c(Provider__c = 'TestProvider', External_Id__c = 'X-1', Status__c = 'Sent', Record_Id__c = opp.Id, File_Name__c = 'Quote.pdf', Unsigned_Content_Version_Id__c = unsignedFile.Id);
        insert request;
        insert new List<DocSigner__c>{
            new DocSigner__c(Sign_Request__c = request.Id, Email__c = 'priya@example.com', Status__c = 'Sent', Routing_Order__c = 1),
            new DocSigner__c(Sign_Request__c = request.Id, Email__c = 'sam@example.com', Status__c = 'Sent', Routing_Order__c = 2)
        };
        DocSignRequest__c loaded = DocBuilderSign.loadRequests(new Set<Id>{ request.Id })[0];

        // Partly signed
        DocBuilderSign.Outcome partial = new DocBuilderSign.Outcome();
        partial.request = loaded;
        partial.status = new DocBuilderSign.StatusResult();
        partial.status.status = 'Sent';
        DocBuilderSign.SignerStatus one = new DocBuilderSign.SignerStatus();
        one.email = 'PRIYA@example.com';
        one.status = 'Signed';
        partial.status.signers.add(one);
        DocBuilderSign.apply(new List<DocBuilderSign.Outcome>{ partial });
        System.assertEquals('Signed', [SELECT Status__c FROM DocSigner__c WHERE Email__c = 'priya@example.com'].Status__c);
        System.assertEquals('Sent', [SELECT Status__c FROM DocSigner__c WHERE Email__c = 'sam@example.com'].Status__c);

        // A provider error is recorded without changing the status
        DocBuilderSign.Outcome failed = new DocBuilderSign.Outcome();
        failed.request = loaded;
        failed.error = 'Provider unreachable';
        DocBuilderSign.apply(new List<DocBuilderSign.Outcome>{ failed });
        DocSignRequest__c after = [SELECT Status__c, Error_Message__c FROM DocSignRequest__c WHERE Id = :request.Id];
        System.assertEquals('Sent', after.Status__c);
        System.assertEquals('Provider unreachable', after.Error_Message__c);

        // Completed with the provider's own signed file
        DocBuilderSign.Outcome done = new DocBuilderSign.Outcome();
        done.request = loaded;
        done.status = new DocBuilderSign.StatusResult();
        done.status.status = 'Completed';
        done.fetched = true;
        done.signedFile = Blob.valueOf('SIGNED-BY-PROVIDER');
        DocBuilderSign.apply(new List<DocBuilderSign.Outcome>{ done });
        after = [SELECT Status__c, Error_Message__c, Completed_On__c, Signed_Content_Version_Id__c FROM DocSignRequest__c WHERE Id = :request.Id];
        System.assertEquals('Completed', after.Status__c);
        System.assertEquals(null, after.Error_Message__c);
        System.assertNotEquals(null, after.Completed_On__c);
        System.assertEquals('SIGNED-BY-PROVIDER', fileText(after.Signed_Content_Version_Id__c));
        System.assertEquals('Signed', [SELECT Status__c FROM DocSigner__c WHERE Email__c = 'sam@example.com'].Status__c);

        System.assertEquals('TestProvider', DocBuilderSign.configFor('TestProvider').name);
        DocBuilderSign.refresh(opp.Id);
    }
}
