@IsTest
public class DocBuilderSourcesTest {
    @TestSetup
    static void grantPermissions() {
        DocBuilderTestUtil.grantAdmin();
    }

    static Map<String, Object> filter(String field, String op, String fromKind, Map<String, Object> extra) {
        Map<String, Object> f = new Map<String, Object>{ 'field' => field, 'op' => op, 'from' => fromKind };
        if (extra != null) {
            f.putAll(extra);
        }
        return f;
    }

    static Opportunity makeData() {
        Account mine = new Account(Name = 'DS Co');
        Account other = new Account(Name = 'Other Co');
        insert new List<Account>{ mine, other };
        insert new List<Contact>{
            new Contact(AccountId = mine.Id, LastName = 'Nair', Department = 'Operations'),
            new Contact(AccountId = mine.Id, LastName = 'Rivera', Department = 'Sales'),
            new Contact(AccountId = other.Id, LastName = 'Stranger', Department = 'Operations')
        };
        Opportunity opp = new Opportunity(AccountId = mine.Id, Name = 'Deal DS', StageName = 'Prospecting', CloseDate = Date.today(), Amount = 3000);
        insert opp;
        return opp;
    }

    static List<Object> dataSources() {
        return new List<Object>{
            // Records related to a related record: the opportunity account's contacts.
            new Map<String, Object>{
                'name' => 'Team',
                'object' => 'Contact',
                'filters' => new List<Object>{ filter('AccountId', 'eq', 'record', new Map<String, Object>{ 'recordField' => 'AccountId' }) },
                'orderBy' => 'LastName',
                'limit' => 10
            },
            // Filtered by a typed value and by the rows of the source above it.
            new Map<String, Object>{
                'name' => 'Ops',
                'object' => 'Contact',
                'filters' => new List<Object>{
                    filter('Department', 'eq', 'value', new Map<String, Object>{ 'value' => 'Operations' }),
                    filter('Id', 'in', 'list', new Map<String, Object>{ 'list' => 'ds:Team', 'listField' => 'Id' })
                }
            },
            // Typed values of each kind are converted to the field's type.
            new Map<String, Object>{
                'name' => 'Deals',
                'object' => 'Opportunity',
                'match' => 'all',
                'filters' => new List<Object>{
                    filter('CloseDate', 'ge', 'value', new Map<String, Object>{ 'value' => '2000-01-01' }),
                    filter('Amount', 'gt', 'value', new Map<String, Object>{ 'value' => '100' }),
                    filter('Name', 'contains', 'value', new Map<String, Object>{ 'value' => 'DS' }),
                    filter('IsPrivate', 'eq', 'value', new Map<String, Object>{ 'value' => 'false' }),
                    filter('NextStep', 'blank', 'value', null),
                    filter('CreatedDate', 'ge', 'value', new Map<String, Object>{ 'value' => '2000-01-01' })
                },
                'orderBy' => 'Name',
                'orderDirection' => 'DESC'
            },
            // Defined but used nowhere: never queried.
            new Map<String, Object>{ 'name' => 'Unused', 'object' => 'Contact' }
        };
    }

    @IsTest
    static void dataSourcesFeedTablesTextConditionsAndTotals() {
        Opportunity opp = makeData();
        List<Object> blocks = new List<Object>{
            new Map<String, Object>{
                'id' => 'team',
                'type' => 'table',
                'source' => 'ds:Team',
                'columns' => new List<Object>{ new Map<String, Object>{ 'header' => 'Who', 'field' => 'LastName' } },
                'totals' => new List<Object>{ new Map<String, Object>{ 'label' => 'People', 'calc' => 'TeamCount' } }
            },
            new Map<String, Object>{ 'id' => 't', 'type' => 'text', 'text' => 'OPS={{ds:Ops.LastName}} ACC={{ds:Team.Account.Name}} {{#if ds:Ops.LastName}}HASOPS{{/if}} DEAL={{ds:Deals.Name}}' }
        };
        List<Object> calculations = new List<Object>{ new Map<String, Object>{ 'name' => 'TeamCount', 'type' => 'count', 'source' => 'ds:Team' } };
        String body = JSON.serialize(new Map<String, Object>{ 'blocks' => blocks, 'calculations' => calculations, 'dataSources' => dataSources() });

        System.assertEquals(null, DocBuilderDesignerController.check(body, 'Opportunity'));
        Integer before = Limits.getQueries();
        String html = DocBuilderEngine.previewHtml(body, 'Opportunity', opp.Id, null, null);
        System.assert(html.contains('Nair') && html.contains('Rivera'), html);
        System.assert(!html.contains('Stranger'), 'Only the account\'s own contacts');
        System.assert(html.contains('OPS=Nair ACC=DS Co HASOPS DEAL=Deal DS'), html);
        System.assert(html.contains('People 2</td>') || html.contains('>2</td>'), html);
        System.assert(html.indexOf('Nair') < html.indexOf('Rivera'), 'Sorted by last name');
        System.assert(Limits.getQueries() - before <= 8, 'The unused source is not queried');

        // A generated document keeps the rows in its audit snapshot.
        Id templateId = DocBuilderSamples.createTemplate('DS', 'Opportunity', null, body);
        DocBuilder.Request req = new DocBuilder.Request();
        req.templateId = templateId;
        req.recordId = opp.Id;
        DocBuilder.Result res = DocBuilder.generate(req);
        System.assert(res.success, res.errorMessage);
        String snapshot = [SELECT Snapshot_JSON__c FROM GeneratedDocument__c WHERE Id = :res.documentId].Snapshot_JSON__c;
        System.assert(snapshot.contains('ds:Team'), snapshot);
    }

    @IsTest
    static void badDataSourcesAreReportedClearly() {
        Map<String, Object> table = new Map<String, Object>{ 'id' => 'x', 'type' => 'table', 'source' => 'ds:Team', 'columns' => new List<Object>{ new Map<String, Object>{ 'field' => 'LastName' } } };
        Map<String, List<Object>> cases = new Map<String, List<Object>>{
            'not defined' => new List<Object>(),
            'needs an object' => new List<Object>{ new Map<String, Object>{ 'name' => 'Team', 'object' => 'No_Such_Object__x' } },
            'is not a valid value' => new List<Object>{
                new Map<String, Object>{ 'name' => 'Team', 'object' => 'Contact', 'filters' => new List<Object>{ filter('Birthdate', 'eq', 'value', new Map<String, Object>{ 'value' => 'soon' }) } }
            },
            'unknown comparison' => new List<Object>{
                new Map<String, Object>{ 'name' => 'Team', 'object' => 'Contact', 'filters' => new List<Object>{ filter('LastName', 'between', 'value', new Map<String, Object>{ 'value' => 'a' }) } }
            },
            'could not be loaded' => new List<Object>{
                new Map<String, Object>{ 'name' => 'Team', 'object' => 'Contact', 'filters' => new List<Object>{ filter('No_Such_Field__c', 'eq', 'value', new Map<String, Object>{ 'value' => 'a' }) } }
            },
            'Two data sources' => new List<Object>{ new Map<String, Object>{ 'name' => 'Team', 'object' => 'Contact' }, new Map<String, Object>{ 'name' => 'Team', 'object' => 'Lead' } }
        };
        List<Object> tooMany = new List<Object>();
        for (Integer i = 0; i < 11; i++) {
            tooMany.add(new Map<String, Object>{ 'name' => 'S' + i, 'object' => 'Contact' });
        }
        cases.put('up to 10', tooMany);
        for (String expected : cases.keySet()) {
            String body = JSON.serialize(new Map<String, Object>{ 'blocks' => new List<Object>{ table }, 'dataSources' => cases.get(expected) });
            String problem = DocBuilderDesignerController.check(body, 'Opportunity');
            System.assert(problem != null && problem.contains(expected), expected + ' -> ' + problem);
        }
        String badName = JSON.serialize(new Map<String, Object>{ 'blocks' => new List<Object>{ new Map<String, Object>{ 'id' => 'x', 'type' => 'table', 'source' => 'ds:1bad' } } });
        System.assert(DocBuilderDesignerController.check(badName, 'Opportunity').contains('not a valid data source name'));
    }

    // ---------- Custom content ----------

    public class Provider implements DocBuilderContentProvider {
        public String render(DocBuilderContentRequest request) {
            return '<table class="t"><tr><td onclick="x()">' + request.settings + ' ' + request.objectName + '</td></tr></table>' +
                '<script>alert(1)</script><a href="javascript:alert(2)">l</a><iframe src="x"></iframe><form action="x"><input name="a"></form>';
        }
    }

    public class Failing implements DocBuilderContentProvider {
        public String render(DocBuilderContentRequest request) {
            Integer zero = 0;
            return String.valueOf(1 / zero);
        }
    }

    @IsTest
    static void customContentFromApexAndVisualforce() {
        Opportunity opp = makeData();
        Map<String, Object> apexBlock = new Map<String, Object>{ 'id' => 'a', 'type' => 'custom', 'source' => 'apex', 'className' => 'DocBuilderSourcesTest.Provider', 'settings' => 'HELLO' };
        String apexBody = JSON.serialize(new Map<String, Object>{ 'blocks' => new List<Object>{ apexBlock } });
        System.assertEquals(null, DocBuilderDesignerController.check(apexBody, 'Opportunity'));
        String html = DocBuilderEngine.previewHtml(apexBody, 'Opportunity', opp.Id, null, null);
        System.assert(html.contains('<table class="t">') && html.contains('HELLO Opportunity'), 'Tables from code are kept: ' + html);
        System.assert(!html.contains('onclick') && !html.contains('<script') && !html.contains('javascript:') && !html.contains('<iframe') && !html.contains('<form') && !html.contains('<input'), html);

        Map<String, Object> vfBlock = new Map<String, Object>{ 'id' => 'v', 'type' => 'custom', 'source' => 'visualforce', 'page' => 'No_Such_Page_Xyz' };
        String vfBody = JSON.serialize(new Map<String, Object>{ 'blocks' => new List<Object>{ vfBlock } });
        System.assert(DocBuilderDesignerController.check(vfBody, 'Opportunity').contains('does not exist'));
        System.assert(DocBuilderEngine.previewHtml(vfBody, 'Opportunity', opp.Id, null, null).contains('[Visualforce page No_Such_Page_Xyz]'));

        System.assert(DocBuilderDesignerController.checkContentClass('Account').contains('does not implement'));
        System.assert(DocBuilderDesignerController.checkContentClass('No_Such_Class_Xyz').contains('no Apex class'));
        System.assert(DocBuilderDesignerController.checkContentClass('bad name!').contains('not a valid'));
        System.assertEquals(null, DocBuilderDesignerController.checkContentClass('DocBuilderSourcesTest.Provider'));
        String missing = JSON.serialize(new Map<String, Object>{ 'blocks' => new List<Object>{ new Map<String, Object>{ 'id' => 'm', 'type' => 'custom', 'source' => 'apex' } } });
        System.assert(DocBuilderDesignerController.check(missing, 'Opportunity').contains('no Apex class chosen'));

        apexBlock.put('className', 'DocBuilderSourcesTest.Failing');
        Id templateId = DocBuilderSamples.createTemplate('Custom', 'Opportunity', null, JSON.serialize(new Map<String, Object>{ 'blocks' => new List<Object>{ apexBlock } }));
        DocBuilder.Request req = new DocBuilder.Request();
        req.templateId = templateId;
        req.recordId = opp.Id;
        DocBuilder.Result res = DocBuilder.generate(req);
        System.assert(!res.success && res.errorMessage.contains('failed'), res.errorMessage);

        System.assertEquals('', DocBuilderRenderer.cleanCode(null));
        System.assertEquals('<p style="color:red">x</p>', DocBuilderRenderer.cleanCode('<html><head><title>t</title></head><body><p style="color:red" onmouseover=\'y()\'>x</p></body></html>'));
    }

    // ---------- Apex checks ----------

    public static Integer calls = 0;

    public class BigDeal implements DocBuilderConditionProvider {
        public Boolean evaluate(DocBuilderContentRequest request) {
            calls++;
            Decimal threshold = String.isBlank(request.settings) ? 1000 : Decimal.valueOf(request.settings);
            return [SELECT Amount FROM Opportunity WHERE Id = :request.recordId].Amount > threshold;
        }
    }

    public class Broken implements DocBuilderConditionProvider {
        public Boolean evaluate(DocBuilderContentRequest request) {
            throw new IllegalArgumentException('no answer');
        }
    }

    @IsTest
    static void apexChecksWorkInRulesAndText() {
        Opportunity opp = makeData();
        List<Object> checks = new List<Object>{
            new Map<String, Object>{ 'name' => 'Big', 'className' => 'DocBuilderSourcesTest.BigDeal' },
            new Map<String, Object>{ 'name' => 'Huge', 'className' => 'DocBuilderSourcesTest.BigDeal', 'settings' => '100000' }
        };
        List<Object> blocks = new List<Object>{
            new Map<String, Object>{
                'id' => 'a',
                'type' => 'text',
                'text' => 'SHOWN-WHEN-BIG',
                'showIf' => new Map<String, Object>{ 'conditions' => new List<Object>{ new Map<String, Object>{ 'field' => 'apex:Big', 'op' => 'eq', 'value' => 'true' } } }
            },
            new Map<String, Object>{
                'id' => 'b',
                'type' => 'text',
                'text' => 'HUGE-BLOCK',
                'showIf' => new Map<String, Object>{ 'conditions' => new List<Object>{ new Map<String, Object>{ 'field' => 'apex:Huge', 'op' => 'eq', 'value' => 'true' } } }
            },
            new Map<String, Object>{ 'id' => 'c', 'type' => 'text', 'text' => '{{#if apex:Big}}IN-TEXT{{else}}NOT{{/if}} {{#if not apex:Huge}}MODEST{{/if}}' }
        };
        String body = JSON.serialize(new Map<String, Object>{ 'blocks' => blocks, 'apexChecks' => checks });
        System.assertEquals(null, DocBuilderDesignerController.check(body, 'Opportunity'));
        calls = 0;
        String html = DocBuilderEngine.previewHtml(body, 'Opportunity', opp.Id, null, null);
        System.assert(html.contains('SHOWN-WHEN-BIG') && !html.contains('HUGE-BLOCK') && html.contains('IN-TEXT') && html.contains('MODEST'), html);
        System.assertEquals(2, calls, 'Each check is asked once per document');

        System.assertEquals(null, DocBuilderDesignerController.checkConditionClass('DocBuilderSourcesTest.BigDeal'));
        System.assert(DocBuilderDesignerController.checkConditionClass('DocBuilderSourcesTest.Provider').contains('does not implement'));

        Map<String, List<Object>> cases = new Map<String, List<Object>>{
            'used but not defined' => new List<Object>(),
            'needs a name' => new List<Object>{ new Map<String, Object>{ 'name' => '1x', 'className' => 'DocBuilderSourcesTest.BigDeal' } },
            'Two Apex variables' => new List<Object>{ checks[0], checks[0] },
            'no Apex class' => new List<Object>{ new Map<String, Object>{ 'name' => 'Big', 'className' => 'No_Such_Class_Xyz' } }
        };
        for (String expected : cases.keySet()) {
            String bad = JSON.serialize(new Map<String, Object>{ 'blocks' => blocks, 'apexChecks' => cases.get(expected) });
            String problem = DocBuilderDesignerController.check(bad, 'Opportunity');
            System.assert(problem != null && problem.contains(expected), expected + ' -> ' + problem);
        }

        String broken = JSON.serialize(
            new Map<String, Object>{ 'blocks' => blocks, 'apexChecks' => new List<Object>{ new Map<String, Object>{ 'name' => 'Big', 'className' => 'DocBuilderSourcesTest.Broken' }, checks[1] } }
        );
        try {
            DocBuilderEngine.previewHtml(broken, 'Opportunity', opp.Id, null, null);
            System.assert(false, 'A failing check stops the document');
        } catch (Exception e) {
            System.assert(e.getMessage().contains('failed: no answer'), e.getMessage());
        }
    }

    public class Facts implements DocBuilderVariableProvider {
        public Map<String, String> describeVariables() {
            return new Map<String, String>{ 'Triple' => 'Number', 'Label' => 'Text', 'Due' => 'Date', 'Zero' => 'Number', 'Flag' => 'Boolean' };
        }
        public Map<String, Object> getValues(DocBuilderContentRequest request) {
            calls++;
            Decimal amount = [SELECT Amount FROM Opportunity WHERE Id = :request.recordId].Amount;
            return new Map<String, Object>{ 'Triple' => amount * 3, 'Label' => 'Tier ' + request.settings, 'Due' => Date.newInstance(2030, 1, 15), 'Zero' => 0, 'Flag' => true };
        }
    }

    static Map<String, Object> apexRule(String name, String op, String value) {
        return new Map<String, Object>{ 'conditions' => new List<Object>{ new Map<String, Object>{ 'field' => 'apex:' + name, 'op' => op, 'value' => value } } };
    }

    @IsTest
    static void oneClassServesManyApexVariables() {
        Opportunity opp = makeData();
        String facts = 'DocBuilderSourcesTest.Facts';
        List<Object> variables = new List<Object>{
            new Map<String, Object>{ 'name' => 'Triple', 'className' => facts, 'variable' => 'Triple', 'settings' => 'Gold', 'type' => 'Number' },
            new Map<String, Object>{ 'name' => 'TierLabel', 'className' => facts, 'variable' => 'Label', 'settings' => 'Gold', 'type' => 'Text' },
            new Map<String, Object>{ 'name' => 'Due', 'className' => facts, 'variable' => 'due', 'settings' => 'Gold', 'type' => 'Date' },
            new Map<String, Object>{ 'name' => 'Zero', 'className' => facts, 'variable' => 'Zero', 'settings' => 'Gold' },
            new Map<String, Object>{ 'name' => 'Big', 'className' => 'DocBuilderSourcesTest.BigDeal' }
        };
        List<Object> blocks = new List<Object>{
            new Map<String, Object>{ 'id' => 'a', 'type' => 'text', 'text' => 'NUM-OK', 'showIf' => apexRule('Triple', 'gt', '8999') },
            new Map<String, Object>{ 'id' => 'b', 'type' => 'text', 'text' => 'NUM-NO', 'showIf' => apexRule('Triple', 'lt', '9000') },
            new Map<String, Object>{ 'id' => 'c', 'type' => 'text', 'text' => 'DATE-OK', 'showIf' => apexRule('Due', 'gt', '2029-12-31') },
            new Map<String, Object>{ 'id' => 'd', 'type' => 'text', 'text' => 'TEXT-OK', 'showIf' => apexRule('TierLabel', 'contains', 'gold') },
            new Map<String, Object>{ 'id' => 'e', 'type' => 'text', 'text' => 'Value {{apex:Triple}} / {{apex:TierLabel}} / {{#if apex:Zero}}ZERO-TRUE{{else}}ZERO-FALSE{{/if}} / {{apex:Big}}' }
        };
        String body = JSON.serialize(new Map<String, Object>{ 'blocks' => blocks, 'apexChecks' => variables });
        System.assertEquals(null, DocBuilderDesignerController.check(body, 'Opportunity'));
        calls = 0;
        String html = DocBuilderEngine.previewHtml(body, 'Opportunity', opp.Id, null, null);
        System.assert(html.contains('NUM-OK') && !html.contains('NUM-NO') && html.contains('DATE-OK') && html.contains('TEXT-OK'), html);
        System.assert(html.contains('Value 9,000 / Tier Gold / ZERO-FALSE / Yes'), html);
        System.assertEquals(2, calls, 'One call for the four Facts variables (same class and settings), one for the yes/no check');

        DocBuilderDesignerController.ApexClassInfo info = DocBuilderDesignerController.describeApexClass(facts);
        System.assert(info.ok && info.kind == 'values' && info.variables.size() == 5, info);
        System.assertEquals('check', DocBuilderDesignerController.describeApexClass('DocBuilderSourcesTest.BigDeal').kind);
        System.assertEquals(false, DocBuilderDesignerController.describeApexClass('Account').ok);

        variables.add(new Map<String, Object>{ 'name' => 'Nope', 'className' => facts, 'variable' => 'Missing' });
        String missing = DocBuilderDesignerController.check(JSON.serialize(new Map<String, Object>{ 'blocks' => blocks, 'apexChecks' => variables }), 'Opportunity');
        System.assert(missing.contains('has no value called "Missing"') && missing.contains('It offers:'), missing);
    }

    @IsTest
    static void tablesCanGroupRowsWithSubtotals() {
        Opportunity opp = makeData();
        insert new Contact(AccountId = opp.AccountId, LastName = 'Bose', Department = 'Operations');
        List<Object> blocks = new List<Object>{
            new Map<String, Object>{
                'id' => 'g',
                'type' => 'table',
                'source' => 'ds:Team',
                'orderBy' => 'Department',
                'groupBy' => 'Department',
                'groupTotals' => true,
                'columns' => new List<Object>{ new Map<String, Object>{ 'header' => 'Who', 'field' => 'LastName' }, new Map<String, Object>{ 'header' => 'Dept', 'field' => 'Department' } },
                'totals' => new List<Object>{ new Map<String, Object>{ 'label' => 'People', 'calc' => 'TeamCount' } }
            }
        };
        String body = JSON.serialize(new Map<String, Object>{
            'blocks' => blocks,
            'calculations' => new List<Object>{ new Map<String, Object>{ 'name' => 'TeamCount', 'type' => 'count', 'source' => 'ds:Team' } },
            'dataSources' => new List<Object>{ dataSources()[0] }
        });
        String html = DocBuilderEngine.previewHtml(body, 'Opportunity', opp.Id, null, null);
        System.assert(html.contains('<tr class="grp"><td colspan="2">Operations</td></tr>') && html.contains('<tr class="grp"><td colspan="2">Sales</td></tr>'), html);
        System.assert(html.contains('Operations: People</td><td class="r">2</td>') && html.contains('Sales: People</td><td class="r">1</td>'), 'Subtotals per group: ' + html);
        System.assert(html.contains('>People</td><td class="r">3</td>'), 'The overall total still follows: ' + html);
        System.assert(html.indexOf('>Operations<') < html.indexOf('>Sales<'), 'Groups follow the sort order');
    }

    @IsTest
    static void pickListsForTheDesigner() {
        Boolean hasAccount = false;
        for (DocBuilderDesignerController.Choice c : DocBuilderDesignerController.listObjects()) {
            hasAccount = hasAccount || c.value == 'Account';
            System.assert(!c.value.endsWith('History') && !c.value.endsWith('Share'), c.value);
        }
        System.assert(hasAccount);
        System.assertNotEquals(null, DocBuilderDesignerController.listVisualforcePages());
    }
}
