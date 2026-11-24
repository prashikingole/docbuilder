/**
 * Holds everything one generation needs: the template body, the source record with its
 * parent fields and child lists, calculated values, rule evaluation and value formatting.
 * It also records every value and rule result it touches, which becomes the audit snapshot.
 */
public with sharing class DocBuilderContext {
    static final Pattern TOKEN = Pattern.compile('\\{\\{\\s*([^}|]+?)\\s*(?:\\|\\s*([A-Za-z]+)\\s*)?\\}\\}');
    static final Pattern SAFE_PATH = Pattern.compile('^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)*$');
    // A name in a formula that is a field: not calc:Name, and not a function such as ROUND( .
    static final Pattern EXPR_IDENT = Pattern.compile('calc:[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_.]*+(?!\\s*\\()');
    static final Integer CHILD_ROW_LIMIT = 500;
    static final Integer SNAPSHOT_LIMIT = 130000;
    // Deepest bracket/function nesting a formula or rule logic may use.
    static final Integer MAX_NESTING = 40;

    public String baseObject;
    public Id recordId;
    public Map<String, Object> body;
    public String fileNamePattern;
    /** The language being generated, passed on to Custom content blocks. Null means the template's default. */
    public String language;
    public SObject record;
    public Map<String, List<SObject>> lists = new Map<String, List<SObject>>();
    public Map<String, Decimal> calcs = new Map<String, Decimal>();
    /** Results of Text by value calculations (type lookup), by name. */
    public Map<String, String> textCalcs = new Map<String, String>();
    public Map<String, Object> usedValues = new Map<String, Object>();
    public Map<String, Object> logicLog = new Map<String, Object>();

    // Lower-cased path -> path as written, so the same field is never selected twice.
    Map<String, String> parentFields = new Map<String, String>{ 'id' => 'Id' };
    Map<String, Map<String, String>> childFields = new Map<String, Map<String, String>>();
    Map<String, String> calcFormats = new Map<String, String>();
    Map<String, Map<String, Schema.SObjectField>> fieldMaps = new Map<String, Map<String, Schema.SObjectField>>();

    public DocBuilderContext(String baseObject, Id recordId, Map<String, Object> body, String fileNamePattern) {
        this.baseObject = safe(baseObject);
        this.recordId = recordId;
        this.body = body == null ? new Map<String, Object>() : body;
        this.fileNamePattern = fileNamePattern;
    }

    // ---------- Template helpers ----------

    public List<Object> blocks() {
        return asList(body.get('blocks'));
    }

    public static List<Object> asList(Object value) {
        return value == null ? new List<Object>() : (List<Object>) value;
    }

    static String safe(String path) {
        if (path == null || !SAFE_PATH.matcher(path.trim()).matches()) {
            throw new DocBuilder.DocBuilderException('"' + path + '" is not a valid field or relationship name.');
        }
        return path.trim();
    }

    // ---------- Loading ----------

    Boolean collected = false;

    public void load() {
        // USER_MODE enforces the running user's object, field and record access.
        List<SObject> rows;
        try {
            rows = Database.queryWithBinds(buildSoql(), new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE);
        } catch (QueryException e) {
            // Names a field from the template, so it is safe and useful to show; nothing internal is included.
            throw new DocBuilder.DocBuilderException('The template uses a field that does not exist or that you cannot see. ' + e.getMessage());
        }
        if (rows.isEmpty()) {
            throw new DocBuilder.DocBuilderException('The record could not be found or you do not have access to it.');
        }
        record = rows[0];
        for (String rel : childFields.keySet()) {
            if (isDataSource(rel)) {
                continue;
            }
            List<SObject> kids = rel.contains('.') ? loadParentList(rel) : record.getSObjects(rel);
            lists.put(rel, kids == null ? new List<SObject>() : kids);
        }
        loadDataSources(null);
        computeCalcs();
    }

    /** Runs the template's queries against no record, to surface missing or inaccessible fields. Returns null when valid. */
    public String check() {
        try {
            Database.queryWithBinds(buildSoql(), new Map<String, Object>{ 'recordId' => null }, AccessLevel.USER_MODE);
            loadDataSources(1);
            return null;
        } catch (Exception e) {
            return e.getMessage();
        }
    }

    // ---------- Apex variables: values from code, used as apex:Name in rules and {{apex:Name}} in text ----------
    // A variable is either a yes/no from a DocBuilderConditionProvider, or one named value of a
    // DocBuilderVariableProvider, which can supply any number of values from a single class.

    static final Pattern CHECK_NAME = Pattern.compile('^[A-Za-z][A-Za-z0-9_]{0,39}$');
    static final Pattern CHECK_CLASS = Pattern.compile('^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)?$');
    Map<String, Object> apexResults = new Map<String, Object>();
    // Class + settings -> every value it supplied, so a class serving several variables runs once per document.
    Map<String, Map<String, Object>> providerValues = new Map<String, Map<String, Object>>();

    /** An instance of an Apex class that implements DocBuilderConditionProvider or DocBuilderVariableProvider. */
    public static Object apexProvider(String className) {
        if (String.isBlank(className) || !CHECK_CLASS.matcher(className.trim()).matches()) {
            throw new DocBuilder.DocBuilderException('"' + className + '" is not a valid Apex class name.');
        }
        Type t = Type.forName(className.trim());
        if (t == null) {
            throw new DocBuilder.DocBuilderException('There is no Apex class called "' + className + '" that DocBuilder can use. It must be global or public in this org.');
        }
        Object instance;
        try {
            instance = t.newInstance();
        } catch (Exception e) {
            throw new DocBuilder.DocBuilderException('Apex class "' + className + '" could not be created: ' + e.getMessage());
        }
        if (!(instance instanceof DocBuilderConditionProvider) && !(instance instanceof DocBuilderVariableProvider)) {
            throw new DocBuilder.DocBuilderException('Apex class "' + className + '" does not implement DocBuilderVariableProvider or DocBuilderConditionProvider.');
        }
        return instance;
    }

    /** Kept for the Apex check API: the class behind a yes/no check. */
    public static DocBuilderConditionProvider conditionProvider(String className) {
        Object instance = apexProvider(className);
        if (!(instance instanceof DocBuilderConditionProvider)) {
            throw new DocBuilder.DocBuilderException('Apex class "' + className + '" does not implement DocBuilderConditionProvider.');
        }
        return (DocBuilderConditionProvider) instance;
    }

    /** The variables a variable provider offers (name -> Boolean, Number, Text or Date), or null for a yes/no check class. */
    public static Map<String, String> variablesOf(String className) {
        Object instance = apexProvider(className);
        if (!(instance instanceof DocBuilderVariableProvider)) {
            return null;
        }
        Map<String, String> described = ((DocBuilderVariableProvider) instance).describeVariables();
        return described == null ? new Map<String, String>() : described;
    }

    static Object valueNamed(Map<String, Object> values, String name) {
        if (values == null || name == null) {
            return null;
        }
        if (values.containsKey(name)) {
            return values.get(name);
        }
        for (String key : values.keySet()) {
            if (key != null && key.equalsIgnoreCase(name)) {
                return values.get(key);
            }
        }
        return null;
    }

    /** An Apex variable's value for this document, worked out once. */
    public Object apexValue(String name) {
        String key = name.trim().toLowerCase();
        if (!apexResults.containsKey(key)) {
            Map<String, Object> def = apexCheckDef(name.trim());
            String className = (String) def.get('className');
            String settings = (String) def.get('settings');
            Object answer;
            try {
                Object provider = apexProvider(className);
                if (provider instanceof DocBuilderVariableProvider) {
                    String cacheKey = className.trim().toLowerCase() + '|' + (settings == null ? '' : settings);
                    if (!providerValues.containsKey(cacheKey)) {
                        providerValues.put(cacheKey, ((DocBuilderVariableProvider) provider).getValues(request(settings)));
                    }
                    String variable = def.get('variable') == null ? name.trim() : String.valueOf(def.get('variable'));
                    answer = valueNamed(providerValues.get(cacheKey), variable);
                } else {
                    answer = ((DocBuilderConditionProvider) provider).evaluate(request(settings)) == true;
                }
            } catch (DocBuilder.DocBuilderException e) {
                throw e;
            } catch (Exception e) {
                throw new DocBuilder.DocBuilderException('The Apex variable "' + name + '" (' + className + ') failed: ' + e.getMessage());
            }
            apexResults.put(key, answer);
            logicLog.put('apex:' + name.trim(), answer);
        }
        return apexResults.get(key);
    }

    DocBuilderContentRequest request(String settings) {
        DocBuilderContentRequest request = new DocBuilderContentRequest();
        request.recordId = recordId;
        request.objectName = baseObject;
        request.settings = settings;
        request.language = language;
        return request;
    }

    /** Whether an Apex variable counts as true in {{#if apex:Name}}: yes, a number other than 0, or any other value. */
    public Boolean apexCheck(String name) {
        Object value = apexValue(name);
        if (value == null) {
            return false;
        }
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        if (value instanceof Decimal || value instanceof Integer || value instanceof Long || value instanceof Double) {
            return Decimal.valueOf(String.valueOf(value)) != 0;
        }
        return String.isNotBlank(String.valueOf(value));
    }

    Map<String, Object> apexCheckDef(String name) {
        for (Object c : asList(body.get('apexChecks'))) {
            Map<String, Object> def = (Map<String, Object>) c;
            if (def.get('name') != null && String.valueOf(def.get('name')).trim().equalsIgnoreCase(name)) {
                return def;
            }
        }
        throw new DocBuilder.DocBuilderException('Apex variable "' + name + '" is used but not defined. Add it under Conditions.');
    }

    /** Null when every Apex variable is named properly and its class (and value) can be used, otherwise the problem. */
    public String checkApexChecks() {
        Set<String> seen = new Set<String>();
        for (Object c : asList(body.get('apexChecks'))) {
            Map<String, Object> def = (Map<String, Object>) c;
            String name = def.get('name') == null ? '' : String.valueOf(def.get('name')).trim();
            if (!CHECK_NAME.matcher(name).matches()) {
                return 'Apex variable "' + name + '" needs a name of letters, digits and underscores.';
            }
            if (!seen.add(name.toLowerCase())) {
                return 'Two Apex variables are called "' + name + '".';
            }
            try {
                Map<String, String> offered = variablesOf((String) def.get('className'));
                String variable = def.get('variable') == null ? name : String.valueOf(def.get('variable'));
                if (offered != null && valueNamed(offered, variable) == null) {
                    return 'Apex variable "' + name + '": ' + def.get('className') + ' has no value called "' + variable + '". It offers: ' + String.join(new List<String>(offered.keySet()), ', ') + '.';
                }
            } catch (Exception e) {
                return 'Apex variable "' + name + '": ' + e.getMessage();
            }
        }
        // Every apex:Name used in rules or text must be defined.
        Matcher used = Pattern.compile('apex:([A-Za-z][A-Za-z0-9_]*)').matcher(JSON.serialize(body));
        while (used.find()) {
            if (!seen.contains(used.group(1).toLowerCase())) {
                return 'Apex variable "' + used.group(1) + '" is used but not defined. Add it under Conditions.';
            }
        }
        return null;
    }
    // ---------- Data sources: extra queries for related-of-related or unrelated records ----------

    static final Pattern DS_KEY = Pattern.compile('^ds:[A-Za-z][A-Za-z0-9_]{0,39}$');
    static final Integer MAX_DATA_SOURCES = 10;
    static final Integer DS_DEFAULT_LIMIT = 200;
    static final Map<String, String> DS_OPERATORS = new Map<String, String>{
        'eq' => '=',
        'ne' => '!=',
        'gt' => '>',
        'ge' => '>=',
        'lt' => '<',
        'le' => '<=',
        'contains' => 'LIKE',
        'in' => 'IN',
        'notIn' => 'NOT IN'
    };

    static Boolean isDataSource(String key) {
        return key != null && key.startsWith('ds:');
    }

    /** A list: a relationship path such as QuoteLineItems or Account.Contacts, or a data source written ds:Name. */
    public static String listKey(String source) {
        if (source != null && source.trim().startsWith('ds:')) {
            String key = source.trim();
            if (!DS_KEY.matcher(key).matches()) {
                throw new DocBuilder.DocBuilderException('"' + source + '" is not a valid data source name. Use letters, digits and underscores.');
            }
            return key;
        }
        return safe(source);
    }

    /** Adds the field a ds:Name.Field path reads to that data source's query. */
    void addDataSourceField(String path) {
        if (!path.contains('.')) {
            throw new DocBuilder.DocBuilderException('"' + path + '" needs a field after the data source name, for example ' + path + '.Name');
        }
        addField(child(listKey(path.substringBefore('.'))), path.substringAfter('.'));
    }

    Map<String, Map<String, Object>> dataSourceDefs;

    /** The template's data sources by key (ds:Name), checked for count, names and duplicates. */
    Map<String, Map<String, Object>> dataSourceDefs() {
        if (dataSourceDefs == null) {
            dataSourceDefs = new Map<String, Map<String, Object>>();
            List<Object> defs = asList(body.get('dataSources'));
            if (defs.size() > MAX_DATA_SOURCES) {
                throw new DocBuilder.DocBuilderException('A template can have up to ' + MAX_DATA_SOURCES + ' data sources.');
            }
            for (Object d : defs) {
                Map<String, Object> def = (Map<String, Object>) d;
                String key = listKey('ds:' + String.valueOf(def.get('name')).trim());
                if (dataSourceDefs.containsKey(key)) {
                    throw new DocBuilder.DocBuilderException('Two data sources are called "' + key.substring(3) + '". Give each a different name.');
                }
                dataSourceDefs.put(key, def);
            }
        }
        return dataSourceDefs;
    }

    /** Collects the record fields and list fields that data source filters compare with. */
    void collectDataSources() {
        for (String key : dataSourceDefs().keySet()) {
            for (Object f : asList(dataSourceDefs().get(key).get('filters'))) {
                Map<String, Object> filter = (Map<String, Object>) f;
                String fromKind = filter.get('from') == null ? 'value' : String.valueOf(filter.get('from'));
                if (fromKind == 'record' && String.isNotBlank((String) filter.get('recordField'))) {
                    addField(parentFields, (String) filter.get('recordField'));
                } else if (fromKind == 'list' && String.isNotBlank((String) filter.get('list'))) {
                    String listName = listKey((String) filter.get('list'));
                    if (isDataSource(listName)) {
                        // Another data source used only as a filter is still loaded.
                        child(listName);
                    }
                    addField(child(listName), (String) filter.get('listField'));
                }
            }
        }
        for (String key : childFields.keySet()) {
            if (isDataSource(key) && !dataSourceDefs().containsKey(key)) {
                throw new DocBuilder.DocBuilderException('Data source "' + key.substring(3) + '" is used in the template but not defined. Add it under Data sources.');
            }
        }
    }

    /** Runs each data source the template uses, in order, so a source can filter by the lists and sources above it. */
    void loadDataSources(Integer rowLimit) {
        for (Object d : asList(body.get('dataSources'))) {
            Map<String, Object> def = (Map<String, Object>) d;
            String key = listKey('ds:' + String.valueOf(def.get('name')).trim());
            if (!childFields.containsKey(key)) {
                continue;
            }
            Map<String, Object> binds = new Map<String, Object>();
            String soql = dataSourceSoql(key, def, binds, rowLimit);
            try {
                lists.put(key, Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE));
            } catch (Exception e) {
                throw new DocBuilder.DocBuilderException('Data source "' + key.substring(3) + '" could not be loaded: ' + e.getMessage());
            }
        }
    }

    /**
     * The query for one data source. Object, fields and operators come from fixed lists or are checked against
     * the schema; every compared value is a bind variable, so nothing from the record or the template is pasted
     * into the query text.
     */
    String dataSourceSoql(String key, Map<String, Object> def, Map<String, Object> binds, Integer rowLimit) {
        String label = key.substring(3);
        String objectName;
        try {
            objectName = Schema.describeSObjects(new List<String>{ safe((String) def.get('object')) })[0].getName();
        } catch (Exception e) {
            throw new DocBuilder.DocBuilderException('Data source "' + label + '" needs an object that exists in this org.');
        }
        Map<String, String> fields = child(key);
        fields.put('id', 'Id');
        List<String> conditions = new List<String>();
        Integer n = 0;
        for (Object f : asList(def.get('filters'))) {
            Map<String, Object> filter = (Map<String, Object>) f;
            if (String.isBlank((String) filter.get('field'))) {
                continue;
            }
            String field = safe((String) filter.get('field'));
            String op = filter.get('op') == null ? 'eq' : String.valueOf(filter.get('op'));
            if (op == 'blank' || op == 'notBlank') {
                conditions.add(field + (op == 'blank' ? ' = null' : ' != null'));
                continue;
            }
            if (!DS_OPERATORS.containsKey(op)) {
                throw new DocBuilder.DocBuilderException('Data source "' + label + '" uses an unknown comparison: ' + op);
            }
            String fromKind = filter.get('from') == null ? 'value' : String.valueOf(filter.get('from'));
            Object value;
            if (fromKind == 'record') {
                value = record == null ? null : resolve(record, safe((String) filter.get('recordField')));
            } else if (fromKind == 'list') {
                value = listValues(listKey((String) filter.get('list')), safe((String) filter.get('listField')));
                if (op != 'in' && op != 'notIn') {
                    op = 'in';
                }
            } else {
                value = typedValue(label, objectName, field, filter.get('value'));
            }
            if ((op == 'in' || op == 'notIn') && !(value instanceof List<Object>) && !(value instanceof List<Id>) && !(value instanceof List<String>) && !(value instanceof List<Decimal>) && !(value instanceof List<Date>)) {
                value = typedList(new List<Object>{ value });
            }
            if (op == 'contains') {
                value = '%' + String.valueOf(value == null ? '' : value).replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%';
            }
            String bind = 'dsv' + n++;
            binds.put(bind, value);
            conditions.add(field + ' ' + DS_OPERATORS.get(op) + ' :' + bind);
        }
        String joiner = 'any'.equalsIgnoreCase((String) def.get('match')) ? ' OR ' : ' AND ';
        String soql = 'SELECT ' + String.join(fields.values(), ', ') + ' FROM ' + objectName;
        if (!conditions.isEmpty()) {
            soql += ' WHERE ' + String.join(conditions, joiner);
        }
        if (String.isNotBlank((String) def.get('orderBy'))) {
            soql += ' ORDER BY ' + safe((String) def.get('orderBy')) + ('DESC'.equalsIgnoreCase((String) def.get('orderDirection')) ? ' DESC NULLS LAST' : ' ASC NULLS LAST');
        }
        Integer limitRows = DS_DEFAULT_LIMIT;
        if (def.get('limit') != null && String.isNotBlank(String.valueOf(def.get('limit')))) {
            limitRows = Decimal.valueOf(String.valueOf(def.get('limit'))).intValue();
        }
        limitRows = Math.max(1, Math.min(CHILD_ROW_LIMIT, limitRows));
        return soql + ' LIMIT ' + (rowLimit == null ? limitRows : rowLimit);
    }

    /** Every distinct value of one field across a list's rows, typed for an IN comparison. */
    Object listValues(String listName, String field) {
        List<Object> values = new List<Object>();
        Set<String> seen = new Set<String>();
        for (SObject row : lists.containsKey(listName) ? lists.get(listName) : new List<SObject>()) {
            Object v = resolve(row, field);
            if (v != null && seen.add(String.valueOf(v))) {
                values.add(v);
            }
        }
        return typedList(values);
    }

    /** SOQL binds an IN list only when the list has a concrete element type. */
    static Object typedList(List<Object> values) {
        Object first;
        for (Object v : values) {
            if (v != null) {
                first = v;
                break;
            }
        }
        if (first instanceof Id) {
            List<Id> out = new List<Id>();
            for (Object v : values) {
                out.add((Id) v);
            }
            return out;
        }
        if (first instanceof Decimal || first instanceof Integer || first instanceof Double || first instanceof Long) {
            List<Decimal> out = new List<Decimal>();
            for (Object v : values) {
                out.add(v == null ? null : Decimal.valueOf(String.valueOf(v)));
            }
            return out;
        }
        if (first instanceof Date) {
            List<Date> out = new List<Date>();
            for (Object v : values) {
                out.add((Date) v);
            }
            return out;
        }
        List<String> out = new List<String>();
        for (Object v : values) {
            out.add(v == null ? null : String.valueOf(v));
        }
        return out;
    }

    /** A typed-in filter value, converted to the field's type (dates, numbers, ticks) so it can be bound. */
    static Object typedValue(String label, String objectName, String path, Object raw) {
        String text = raw == null ? '' : String.valueOf(raw).trim();
        if (text == '') {
            return null;
        }
        Schema.DisplayType type = fieldType(objectName, path);
        try {
            if (type == Schema.DisplayType.DATE) {
                return Date.valueOf(text);
            }
            if (type == Schema.DisplayType.DATETIME) {
                return text.length() == 10 ? Datetime.newInstance(Date.valueOf(text), Time.newInstance(0, 0, 0, 0)) : Datetime.valueOf(text.replace('T', ' ').removeEnd('Z'));
            }
            if (type == Schema.DisplayType.CURRENCY || type == Schema.DisplayType.DOUBLE || type == Schema.DisplayType.PERCENT) {
                return Decimal.valueOf(text);
            }
            if (type == Schema.DisplayType.INTEGER) {
                return Integer.valueOf(text);
            }
            if (type == Schema.DisplayType.LONG) {
                return Long.valueOf(text);
            }
            if (type == Schema.DisplayType.BOOLEAN) {
                return Boolean.valueOf(text);
            }
        } catch (Exception e) {
            throw new DocBuilder.DocBuilderException('Data source "' + label + '": "' + text + '" is not a valid value for ' + path + '.');
        }
        return text;
    }

    /** The type of a field path such as Account.Industry on the given object, or null when it cannot be found. */
    static Schema.DisplayType fieldType(String objectName, String path) {
        Schema.DescribeSObjectResult d = Schema.describeSObjects(new List<String>{ objectName })[0];
        List<String> parts = path.split('\\.');
        for (Integer i = 0; i < parts.size() - 1; i++) {
            Schema.DescribeFieldResult lookup;
            for (Schema.SObjectField f : d.fields.getMap().values()) {
                Schema.DescribeFieldResult fd = f.getDescribe();
                if (fd.getRelationshipName() != null && fd.getRelationshipName().equalsIgnoreCase(parts[i]) && !fd.getReferenceTo().isEmpty()) {
                    lookup = fd;
                    break;
                }
            }
            if (lookup == null) {
                return null;
            }
            d = lookup.getReferenceTo()[0].getDescribe();
        }
        Schema.SObjectField field = d.fields.getMap().get(parts[parts.size() - 1]);
        return field == null ? null : field.getDescribe().getType();
    }

    String buildSoql() {
        if (!collected) {
            collect();
            collected = true;
        }
        for (String rel : childFields.keySet()) {
            if (rel.contains('.') && !isDataSource(rel)) {
                // A list on a related record, e.g. Account.Contacts: we need the related record's Id first.
                addField(parentFields, rel.substringBeforeLast('.') + '.Id');
            }
        }
        List<String> selects = new List<String>(parentFields.values());
        for (String rel : childFields.keySet()) {
            if (!rel.contains('.') && !isDataSource(rel)) {
                selects.add(subquery(rel, rel));
            }
        }
        return 'SELECT ' + String.join(selects, ', ') + ' FROM ' + baseObject + ' WHERE Id = :recordId LIMIT 1';
    }

    String subquery(String key, String relationshipName) {
        Map<String, String> fields = childFields.get(key);
        fields.put('id', 'Id');
        return '(SELECT ' + String.join(fields.values(), ', ') + ' FROM ' + relationshipName + ' LIMIT ' + CHILD_ROW_LIMIT + ')';
    }

    List<SObject> loadParentList(String rel) {
        String childRel = rel.substringAfterLast('.');
        SObject parent = record;
        for (String part : rel.substringBeforeLast('.').split('\\.')) {
            if (parent == null) {
                return null;
            }
            parent = parent.getSObject(part);
        }
        if (parent == null || parent.Id == null) {
            return null;
        }
        Id parentId = parent.Id;
        String soql = 'SELECT Id, ' + subquery(rel, childRel) + ' FROM ' + String.valueOf(parentId.getSObjectType()) + ' WHERE Id = :parentId LIMIT 1';
        List<SObject> rows = Database.queryWithBinds(soql, new Map<String, Object>{ 'parentId' => parentId }, AccessLevel.USER_MODE);
        return rows.isEmpty() ? null : rows[0].getSObjects(childRel);
    }

    void collect() {
        addTokens(fileNamePattern, null);
        for (String key : new List<String>{ 'header', 'footer', 'watermark' }) {
            Map<String, Object> part = section(key);
            addTokens((String) part.get('text'), null);
            addRule(part.get('showIf'), null);
        }
        for (String key : MESSAGE_KEYS) {
            addTokens((String) messages().get(key), null);
        }
        for (Object s : asList(body.get('signers'))) {
            Map<String, Object> signer = (Map<String, Object>) s;
            String source = (String) signer.get('source');
            if (String.isNotBlank(source)) {
                String rel = listKey(source);
                addField(child(rel), String.isBlank((String) signer.get('nameField')) ? 'Name' : (String) signer.get('nameField'));
                if (String.isBlank((String) signer.get('emailField'))) {
                    throw new DocBuilder.DocBuilderException('Signers taken from ' + source + ' need an email field.');
                }
                addField(child(rel), (String) signer.get('emailField'));
                addRule(signer.get('filter'), rel);
                continue;
            }
            addTokens((String) signer.get('name'), null);
            addTokens((String) signer.get('email'), null);
        }
        for (Object b : blocks()) {
            Map<String, Object> blk = (Map<String, Object>) b;
            String type = (String) blk.get('type');
            addRule(blk.get('showIf'), null);
            addTokens((String) blk.get('elseText'), null);
            if (type == 'table') {
                String rel = listKey((String) blk.get('source'));
                child(rel);
                for (Object c : asList(blk.get('columns'))) {
                    addField(child(rel), (String) ((Map<String, Object>) c).get('field'));
                    // A column can be shown only when a rule on the record is met.
                    addRule(((Map<String, Object>) c).get('showIf'), null);
                }
                addRule(blk.get('rowFilter'), rel);
                // Each table sorts its own rows (see sorted), so several tables can show one list in different orders.
                String orderBy = (String) blk.get('orderBy');
                if (String.isNotBlank(orderBy)) {
                    addField(child(rel), orderBy);
                }
                if (String.isNotBlank((String) blk.get('groupBy'))) {
                    addField(child(rel), (String) blk.get('groupBy'));
                }
            } else if (type == 'terms') {
                addTokens((String) blk.get('title'), null);
                for (Object i : asList(blk.get('items'))) {
                    Map<String, Object> item = (Map<String, Object>) i;
                    addTokens((String) item.get('text'), null);
                    addRule(item.get('showIf'), null);
                }
            } else {
                addTokens((String) blk.get('text'), null);
            }
        }
        for (Object c : asList(body.get('calculations'))) {
            Map<String, Object> calc = (Map<String, Object>) c;
            calcFormats.put((String) calc.get('name'), (String) calc.get('format'));
            if ('lookup'.equalsIgnoreCase((String) calc.get('type'))) {
                // Text by value: the field it reads, and any fields used in its texts.
                String field = (String) calc.get('field');
                if (String.isNotBlank(field) && isDataSource(field)) {
                    addDataSourceField(field);
                } else if (String.isNotBlank(field) && !field.startsWith('calc:') && !field.startsWith('apex:')) {
                    addField(parentFields, field);
                }
                for (Object k : asList(calc.get('cases'))) {
                    addTokens((String) ((Map<String, Object>) k).get('text'), null);
                }
                addTokens((String) calc.get('otherwise'), null);
                continue;
            }
            if ('formula'.equalsIgnoreCase((String) calc.get('type'))) {
                Matcher m = EXPR_IDENT.matcher(calc.get('expression') == null ? '' : (String) calc.get('expression'));
                while (m.find()) {
                    if (!m.group().startsWith('calc:')) {
                        addField(parentFields, m.group());
                    }
                }
                continue;
            }
            String rel = listKey((String) calc.get('source'));
            child(rel);
            if (calc.get('field') != null) {
                addField(child(rel), (String) calc.get('field'));
            }
            addRule(calc.get('filter'), rel);
        }
        for (Object c : asList(body.get('conditions'))) {
            addRule(((Map<String, Object>) c).get('rule'), null);
        }
        collectDataSources();
    }

    Map<String, String> child(String rel) {
        if (!childFields.containsKey(rel)) {
            childFields.put(rel, new Map<String, String>());
        }
        return childFields.get(rel);
    }

    void addField(Map<String, String> target, String path) {
        String clean = safe(path);
        target.put(clean.toLowerCase(), clean);
    }

    void addTokens(String text, String rel) {
        if (String.isBlank(text)) {
            return;
        }
        Matcher s = SECTION.matcher(text);
        while (s.find()) {
            String target = sectionTarget(s.group(1));
            if (target != null && isDataSource(target)) {
                addDataSourceField(target);
            } else if (target != null && !target.startsWith('cond:') && !target.startsWith('apex:')) {
                addField(rel == null ? parentFields : child(rel), target);
            }
        }
        Matcher m = TOKEN.matcher(SECTION.matcher(text).replaceAll(''));
        while (m.find()) {
            String path = m.group(1).trim();
            if (isDataSource(path)) {
                // {{ds:Name.Field}} prints the field from the data source's first row.
                addDataSourceField(path);
            } else if (!path.startsWith('calc:') && !path.startsWith('apex:')) {
                addField(rel == null ? parentFields : child(rel), path);
            }
        }
    }

    // ---------- Conditions inside text: {{#if Field}} ... {{else}} ... {{/if}} ----------

    static final Pattern SECTION = Pattern.compile('(?i)\\{\\{\\s*(#if\\s+[^}]+?|else|/if)\\s*\\}\\}');

    /** The field or cond:Name a section tests, without any leading "not". Null for else and /if. */
    static String sectionTarget(String tag) {
        String t = tag.trim();
        if (!t.toLowerCase().startsWith('#if')) {
            return null;
        }
        t = t.substring(3).trim();
        if (t.toLowerCase().startsWith('not ')) {
            t = t.substring(4).trim();
        }
        return t;
    }

    Map<String, Object> namedRules;

    Map<String, Object> namedRules() {
        if (namedRules == null) {
            namedRules = new Map<String, Object>();
            for (Object c : asList(body.get('conditions'))) {
                Map<String, Object> condition = (Map<String, Object>) c;
                if (condition.get('name') != null) {
                    namedRules.put(String.valueOf(condition.get('name')).trim().toLowerCase(), condition.get('rule'));
                }
            }
        }
        return namedRules;
    }

    Boolean sectionShows(String tag, SObject source) {
        String t = tag.trim().substring(3).trim();
        Boolean negate = t.toLowerCase().startsWith('not ');
        String target = sectionTarget(tag);
        Boolean result;
        if (target.startsWith('apex:')) {
            result = apexCheck(target.substring(5).trim());
            logicLog.put(target, result);
        } else if (target.startsWith('cond:')) {
            String name = target.substring(5).trim();
            if (!namedRules().containsKey(name.toLowerCase())) {
                throw new DocBuilder.DocBuilderException('Condition "' + name + '" is used in text but not defined in the template.');
            }
            Object rule = namedRules().get(name.toLowerCase());
            result = rule == null ? true : passes(rule, record, 'cond:' + name);
        } else {
            String path = isDataSource(target) ? target : safe(target);
            Object value = resolve(source, path);
            if (source === record) {
                usedValues.put(path, value);
            }
            result = value != null && String.valueOf(value) != '';
        }
        return negate ? !result : result;
    }

    /** Keeps or drops the parts of text wrapped in {{#if}} sections. Sections can be nested and can have an {{else}}. */
    public String applySections(String text, SObject source) {
        if (String.isBlank(text) || !text.contains('{{')) {
            return text;
        }
        Matcher m = SECTION.matcher(text);
        List<Boolean> parentShows = new List<Boolean>();
        List<Boolean> conditionHolds = new List<Boolean>();
        List<Boolean> showing = new List<Boolean>();
        Boolean show = true;
        String out = '';
        Integer last = 0;
        while (m.find()) {
            if (show) {
                out += text.substring(last, m.start());
            }
            last = m.end();
            String tag = m.group(1).trim().toLowerCase();
            if (tag.startsWith('#if')) {
                Boolean holds = show ? sectionShows(m.group(1), source) : false;
                parentShows.add(show);
                conditionHolds.add(holds);
                show = show && holds;
                showing.add(show);
            } else if (tag == 'else') {
                if (showing.isEmpty()) {
                    throw new DocBuilder.DocBuilderException('Text has an {{else}} outside an {{#if}}.');
                }
                Integer top = showing.size() - 1;
                show = parentShows[top] && !conditionHolds[top];
                showing[top] = show;
            } else {
                if (showing.isEmpty()) {
                    throw new DocBuilder.DocBuilderException('Text has an {{/if}} without a matching {{#if}}.');
                }
                Integer top = showing.size() - 1;
                show = parentShows[top];
                parentShows.remove(top);
                conditionHolds.remove(top);
                showing.remove(top);
            }
        }
        if (!showing.isEmpty()) {
            throw new DocBuilder.DocBuilderException('Text has an {{#if}} without a matching {{/if}}.');
        }
        return show ? out + text.substring(last) : out;
    }

    // ---------- Sorting a table's rows ----------

    /** A copy of the rows sorted by one field, empty values last. Used per table, so each table can have its own order. */
    public List<SObject> sorted(List<SObject> rows, String path, Boolean descending) {
        if (String.isBlank(path) || rows.size() < 2) {
            return rows;
        }
        List<SObject> copy = new List<SObject>(rows);
        copy.sort(new RowOrder(this, safe(path), descending == true));
        return copy;
    }

    public class RowOrder implements Comparator<SObject> {
        DocBuilderContext ctx;
        String path;
        Boolean descending;

        public RowOrder(DocBuilderContext ctx, String path, Boolean descending) {
            this.ctx = ctx;
            this.path = path;
            this.descending = descending;
        }

        public Integer compare(SObject a, SObject b) {
            Object x = ctx.resolve(a, path);
            Object y = ctx.resolve(b, path);
            if (x == null || y == null) {
                return x == null && y == null ? 0 : (x == null ? 1 : -1);
            }
            Integer result;
            if (x instanceof Date) {
                result = (Date) x < (Date) y ? -1 : ((Date) x > (Date) y ? 1 : 0);
            } else if (x instanceof Datetime) {
                result = (Datetime) x < (Datetime) y ? -1 : ((Datetime) x > (Datetime) y ? 1 : 0);
            } else if (x instanceof Decimal || x instanceof Integer || x instanceof Long || x instanceof Double) {
                Decimal dx = Decimal.valueOf(String.valueOf(x));
                Decimal dy = Decimal.valueOf(String.valueOf(y));
                result = dx < dy ? -1 : (dx > dy ? 1 : 0);
            } else {
                result = String.valueOf(x).toLowerCase().compareTo(String.valueOf(y).toLowerCase());
            }
            return descending ? -result : result;
        }
    }

    void addRule(Object ruleObj, String rel) {
        if (ruleObj == null) {
            return;
        }
        for (Object c : asList(((Map<String, Object>) ruleObj).get('conditions'))) {
            String field = (String) ((Map<String, Object>) c).get('field');
            if (field != null && isDataSource(field) && rel == null) {
                addDataSourceField(field);
            } else if (field != null && !field.startsWith('calc:') && !field.startsWith('apex:')) {
                addField(rel == null ? parentFields : child(rel), field);
            }
        }
    }

    // Calculation name -> its definition, for totals that are worked out again per table.
    Map<String, Map<String, Object>> calcDefs = new Map<String, Map<String, Object>>();

    void computeCalcs() {
        for (Object c : asList(body.get('calculations'))) {
            Map<String, Object> calc = (Map<String, Object>) c;
            String name = (String) calc.get('name');
            calcDefs.put(name, calc);
            String type = calc.get('type') == null ? 'count' : ((String) calc.get('type')).toLowerCase();
            if (type == 'formula') {
                calcs.put(name, new ExprParser((String) calc.get('expression'), this).evaluate());
                continue;
            }
            if (type == 'lookup') {
                textCalcs.put(name, lookupText(calc));
                continue;
            }
            List<SObject> rows = rowsFor((String) calc.get('source'), calc.get('filter'));
            calcs.put(name, aggregate(name, type, (String) calc.get('field'), rows));
            // With no format chosen, a total of money or percentages prints like the field it adds up.
            String listName = (String) calc.get('source');
            List<SObject> all = listName != null && lists.containsKey(listName) ? lists.get(listName) : rows;
            if (String.isBlank(calcFormats.get(name)) && type != 'count' && calc.get('field') != null && !all.isEmpty()) {
                Schema.DisplayType fieldType = typeOf(all[0], (String) calc.get('field'));
                if (fieldType == Schema.DisplayType.CURRENCY) {
                    calcFormats.put(name, 'currency');
                } else if (fieldType == Schema.DisplayType.PERCENT) {
                    calcFormats.put(name, 'percent');
                }
            }
        }
    }

    /** Count, sum, average, lowest or highest of one field over some rows. */
    Decimal aggregate(String name, String type, String field, List<SObject> rows) {
        if (type == 'count') {
            return rows.size();
        }
        Decimal total = 0;
        Decimal lowest;
        Decimal highest;
        Integer counted = 0;
        for (SObject row : rows) {
            Object raw = resolve(row, field);
            if (raw == null) {
                continue;
            }
            Decimal value = Decimal.valueOf(String.valueOf(raw));
            total += value;
            counted++;
            lowest = lowest == null || value < lowest ? value : lowest;
            highest = highest == null || value > highest ? value : highest;
        }
        if (type == 'sum') {
            return total;
        } else if (type == 'avg') {
            return counted == 0 ? 0 : (total / counted).setScale(2, RoundingMode.HALF_UP);
        } else if (type == 'min') {
            return lowest == null ? 0 : lowest;
        } else if (type == 'max') {
            return highest == null ? 0 : highest;
        }
        throw new DocBuilder.DocBuilderException('Calculation "' + name + '" has an unknown type: ' + type);
    }

    /**
     * A summary row under a table. When the calculated value totals the same list the table shows, it is
     * worked out over the rows the table actually shows (after its row filter), so a filtered table never
     * shows the total of rows it left out. Other calculated values print as they are.
     */
    public String formatTableTotal(String name, String format, String tableSource, List<SObject> shownRows) {
        Map<String, Object> calc = calcDefs.get(name);
        String type = calc == null || calc.get('type') == null ? 'count' : ((String) calc.get('type')).toLowerCase();
        String source = calc == null ? null : (String) calc.get('source');
        if (calc == null || type == 'formula' || String.isBlank(source) || String.isBlank(tableSource) || !source.trim().equalsIgnoreCase(tableSource.trim())) {
            return formatCalc(name, format);
        }
        List<SObject> rows = shownRows;
        if (calc.get('filter') != null) {
            rows = new List<SObject>();
            for (SObject row : shownRows) {
                if (passes(calc.get('filter'), row, null)) {
                    rows.add(row);
                }
            }
        }
        Decimal value = aggregate(name, type, (String) calc.get('field'), rows);
        String chosen = String.isNotBlank(format) ? format : calcFormats.get(name);
        return applyFormat(value, String.isBlank(chosen) ? 'number' : chosen);
    }

    /** Child rows of a relationship, optionally narrowed by a row filter rule. */
    public List<SObject> rowsFor(String rel, Object filter) {
        List<SObject> all = lists.containsKey(rel) ? lists.get(rel) : new List<SObject>();
        if (filter == null) {
            return all;
        }
        List<SObject> kept = new List<SObject>();
        for (SObject row : all) {
            if (passes(filter, row, null)) {
                kept.add(row);
            }
        }
        return kept;
    }

    // ---------- Values and formatting ----------

    /**
     * The parts of a field path, read from the given record. A leading object name that is the record's own
     * type is dropped, so {{Quote.Name}} on a Quote template means the quote's Name, just as SOQL allows.
     */
    List<String> partsOf(SObject source, String path) {
        List<String> parts = path.split('\\.');
        if (parts.size() > 1 && source != null && parts[0].equalsIgnoreCase(String.valueOf(source.getSObjectType()))) {
            parts.remove(0);
        }
        return parts;
    }

    /** The first row of a data source, for paths written ds:Name.Field. Null when the source has no rows. */
    SObject firstRowOf(String path) {
        List<SObject> rows = lists.get(path.substringBefore('.'));
        return rows == null || rows.isEmpty() ? null : rows[0];
    }

    public Object resolve(SObject source, String path) {
        if (path != null && path.startsWith('apex:')) {
            // {{apex:Name}} prints an Apex variable.
            return apexValue(path.substring(5));
        }
        if (isDataSource(path)) {
            SObject first = firstRowOf(path);
            return first == null ? null : resolve(first, path.substringAfter('.'));
        }
        List<String> parts = partsOf(source, path);
        SObject current = source;
        try {
            for (Integer i = 0; i < parts.size() - 1; i++) {
                if (current == null) {
                    return null;
                }
                current = current.getSObject(parts[i]);
            }
            return current == null ? null : current.get(parts[parts.size() - 1]);
        } catch (SObjectException e) {
            throw new DocBuilder.DocBuilderException(
                'The template uses "' + path + '", which is not a field or related record on ' + String.valueOf(source.getSObjectType()) + '. Check the template\'s text and file name.'
            );
        }
    }

    Schema.DisplayType typeOf(SObject source, String path) {
        if (path != null && path.startsWith('apex:')) {
            return null;
        }
        if (isDataSource(path)) {
            SObject first = firstRowOf(path);
            return first == null ? null : typeOf(first, path.substringAfter('.'));
        }
        List<String> parts = partsOf(source, path);
        SObject current = source;
        for (Integer i = 0; i < parts.size() - 1; i++) {
            if (current == null) {
                return null;
            }
            current = current.getSObject(parts[i]);
        }
        if (current == null) {
            return null;
        }
        String key = String.valueOf(current.getSObjectType());
        if (!fieldMaps.containsKey(key)) {
            fieldMaps.put(key, current.getSObjectType().getDescribe().fields.getMap());
        }
        Schema.SObjectField field = fieldMaps.get(key).get(parts[parts.size() - 1]);
        return field == null ? null : field.getDescribe().getType();
    }

    public String formatValue(SObject source, String path, String format) {
        Object value = resolve(source, path);
        if (source === record) {
            usedValues.put(path, value);
        }
        if (value == null) {
            return '';
        }
        if (String.isNotBlank(format)) {
            return applyFormat(value, format);
        }
        Schema.DisplayType type = typeOf(source, path);
        if (type == Schema.DisplayType.CURRENCY) {
            return applyFormat(value, 'currency');
        }
        if (type == Schema.DisplayType.PERCENT) {
            return applyFormat(value, 'percent');
        }
        if (type == Schema.DisplayType.DATE) {
            return ((Date) value).format();
        }
        if (type == Schema.DisplayType.DATETIME) {
            return ((Datetime) value).format();
        }
        if (type == Schema.DisplayType.DOUBLE || type == Schema.DisplayType.INTEGER || type == Schema.DisplayType.LONG) {
            return applyFormat(value, 'number');
        }
        // Values without a field type, such as Apex variables, print by their own kind.
        if (type == null && value instanceof Date) {
            return ((Date) value).format();
        }
        if (type == null && value instanceof Datetime) {
            return ((Datetime) value).format();
        }
        if (type == null && (value instanceof Decimal || value instanceof Integer || value instanceof Long || value instanceof Double)) {
            return applyFormat(value, 'number');
        }
        if (value instanceof Boolean) {
            return value == true ? 'Yes' : 'No';
        }
        return String.valueOf(value);
    }

    /**
     * Text by value: the text of the first row whose value matches the field, otherwise the "otherwise" text.
     * Values match ignoring case; numbers match as numbers; a multi-select picklist matches any selected value;
     * a row with an empty value matches when the field is empty. Fields in the texts are filled in.
     */
    String lookupText(Map<String, Object> calc) {
        String field = (String) calc.get('field');
        Object raw;
        if (String.isNotBlank(field)) {
            raw = field.startsWith('calc:') ? calcValue(field.substring(5)) : resolve(record, field);
            if (!field.startsWith('calc:') && !field.startsWith('apex:') && !isDataSource(field)) {
                usedValues.put(field, raw);
            }
        }
        String actual = raw == null ? '' : String.valueOf(raw).trim();
        Set<String> selected = new Set<String>();
        for (String part : actual.split(';')) {
            selected.add(part.trim().toLowerCase());
        }
        Decimal actualNumber = numberOrNull(raw);
        for (Object k : asList(calc.get('cases'))) {
            Map<String, Object> row = (Map<String, Object>) k;
            String want = row.get('value') == null ? '' : String.valueOf(row.get('value')).trim();
            Decimal wantNumber = numberOrNull(want);
            Boolean matches =
                actual.equalsIgnoreCase(want) ||
                (want != '' && selected.contains(want.toLowerCase())) ||
                (actualNumber != null && wantNumber != null && actualNumber == wantNumber);
            if (matches) {
                return mergeText((String) row.get('text'), record, false);
            }
        }
        return mergeText((String) calc.get('otherwise'), record, false);
    }

    static Decimal numberOrNull(Object value) {
        if (value == null || value instanceof Boolean || value instanceof Date || value instanceof Datetime) {
            return null;
        }
        try {
            return Decimal.valueOf(String.valueOf(value).trim());
        } catch (Exception e) {
            return null;
        }
    }

    /** Every calculated value, numbers and texts, for the audit snapshot and the designer. */
    public Map<String, Object> allCalcValues() {
        Map<String, Object> all = new Map<String, Object>();
        for (String name : calcs.keySet()) {
            all.put(name, calcs.get(name));
        }
        for (String name : textCalcs.keySet()) {
            all.put(name, textCalcs.get(name));
        }
        return all;
    }

    /** A calculated value: a number, or the text of a Text by value calculation. */
    public Object calcValue(String name) {
        return textCalcs.containsKey(name) ? (Object) textCalcs.get(name) : (Object) calcs.get(name);
    }

    public String formatCalc(String name, String format) {
        if (textCalcs.containsKey(name)) {
            String text = textCalcs.get(name);
            // Text takes the text formats only (upper, lower); number formats leave it as it is.
            return String.isNotBlank(format) && (format.equalsIgnoreCase('upper') || format.equalsIgnoreCase('lower')) ? applyFormat(text, format) : text;
        }
        if (!calcs.containsKey(name)) {
            throw new DocBuilder.DocBuilderException('Calculated value "' + name + '" is not defined in the template.');
        }
        String chosen = String.isNotBlank(format) ? format : calcFormats.get(name);
        return applyFormat(calcs.get(name), String.isBlank(chosen) ? 'number' : chosen);
    }

    String applyFormat(Object value, String format) {
        String f = format.toLowerCase();
        if (f == 'upper') {
            return String.valueOf(value).toUpperCase();
        }
        if (f == 'lower') {
            return String.valueOf(value).toLowerCase();
        }
        if (f == 'date' && value instanceof Datetime) {
            return ((Datetime) value).date().format();
        }
        if (f == 'currency' || f == 'number' || f == 'percent') {
            Decimal d;
            try {
                d = Decimal.valueOf(String.valueOf(value));
            } catch (Exception e) {
                return String.valueOf(value);
            }
            if (f == 'currency') {
                d = d.setScale(2, RoundingMode.HALF_UP);
                String plain = d.abs().toPlainString();
                String whole = Long.valueOf(plain.substringBefore('.')).format();
                return (d < 0 ? '-' : '') + UserInfo.getDefaultCurrency() + ' ' + whole + '.' + plain.substringAfter('.');
            }
            if (f == 'percent') {
                return d.stripTrailingZeros().toPlainString() + '%';
            }
            return d.format();
        }
        return String.valueOf(value);
    }

    /** Replaces {{Field.Path}} and {{calc:Name}} tokens. With html=true the result is safe to place in markup. */
    public String mergeText(String text, SObject source, Boolean html) {
        if (String.isBlank(text)) {
            return '';
        }
        text = applySections(text, source);
        Matcher m = TOKEN.matcher(text);
        String out = '';
        Integer last = 0;
        while (m.find()) {
            out += escape(text.substring(last, m.start()), html);
            String path = m.group(1).trim();
            String value = path.startsWith('calc:') ? formatCalc(path.substring(5), m.group(2)) : formatValue(source, path, m.group(2));
            out += escape(value, html);
            last = m.end();
        }
        out += escape(text.substring(last), html);
        return html ? out.replace('\r\n', '<br/>').replace('\n', '<br/>') : out;
    }

    public String mergeHtml(String text) {
        return mergeText(text, record, true);
    }

    /**
     * Merges tokens into rich text. The author's formatting is kept, unsafe markup is removed,
     * and every merged value is escaped so data can never inject markup.
     */
    public String mergeRich(String html) {
        if (String.isBlank(html)) {
            return '';
        }
        // Sections are resolved first, so a condition can never leave half a tag behind once cleaned.
        String clean = sanitize(applySections(html, record));
        Matcher m = TOKEN.matcher(clean);
        String out = '';
        Integer last = 0;
        while (m.find()) {
            out += clean.substring(last, m.start());
            String path = m.group(1).trim();
            String value = path.startsWith('calc:') ? formatCalc(path.substring(5), m.group(2)) : formatValue(record, path, m.group(2));
            out += value == null ? '' : value.escapeHtml4();
            last = m.end();
        }
        return out + clean.substring(last);
    }

    // ---------- Rich text cleaning (allowlist) ----------

    static final Set<String> RICH_TAGS = new Set<String>{
        'p', 'br', 'b', 'strong', 'i', 'em', 'u', 's', 'strike', 'ul', 'ol', 'li', 'span', 'div', 'h1', 'h2', 'h3', 'h4', 'blockquote', 'sub', 'sup', 'hr'
    };
    static final Set<String> VOID_TAGS = new Set<String>{ 'br', 'hr' };
    // Elements whose content is never meant to be shown as text; removed together with their content.
    static final Pattern DROP_WITH_CONTENT = Pattern.compile('(?is)<(script|style|iframe|object|embed|noscript|template|textarea|title|svg|math|select)\\b.*?</\\1\\s*>');
    static final Pattern TAG = Pattern.compile('<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>');
    static final Pattern ATTR = Pattern.compile('([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*("([^"]*)"|\'([^\']*)\'|([^\\s"\'>]+))');
    static final Pattern CLASS_OK = Pattern.compile('^\\s*(ql-[a-z0-9-]+\\s*)+$');
    static final Pattern COLOUR = Pattern.compile('^(#[0-9a-fA-F]{3,8}|rgba?\\(\\s*[0-9]{1,3}%?\\s*,\\s*[0-9]{1,3}%?\\s*,\\s*[0-9]{1,3}%?\\s*(,\\s*[0-9.]{1,4}\\s*)?\\)|[a-zA-Z]{3,20})$');
    static final Map<String, Pattern> STYLE_OK = new Map<String, Pattern>{
        'color' => COLOUR,
        'background-color' => COLOUR,
        'text-align' => Pattern.compile('^(left|right|center|justify)$'),
        'font-size' => Pattern.compile('^[0-9]{1,3}(\\.[0-9]{1,2})?(px|pt|em|rem|%)$'),
        'font-weight' => Pattern.compile('^(normal|bold|[1-9]00)$'),
        'font-style' => Pattern.compile('^(normal|italic)$'),
        'font-family' => Pattern.compile('^[a-zA-Z0-9 ,\'-]{1,80}$'),
        'text-decoration' => Pattern.compile('^(none|underline|line-through)$')
    };

    /**
     * Cleans rich text from the template author with an allowlist: only simple formatting tags survive,
     * each rebuilt with only a class (Quill's own ql- classes) and a few checked style properties.
     * Everything else is dropped: links, images, event handlers, URLs and anything entity-encoded,
     * because only plain values can match the allowed patterns. Stray angle brackets become text.
     */
    public static String sanitize(String html) {
        if (String.isBlank(html)) {
            return '';
        }
        String source = DROP_WITH_CONTENT.matcher(html).replaceAll('');
        String out = '';
        Matcher m = TAG.matcher(source);
        Integer last = 0;
        while (m.find()) {
            out += escapeText(source.substring(last, m.start()));
            last = m.end();
            String name = m.group(2).toLowerCase();
            if (!RICH_TAGS.contains(name)) {
                continue;
            }
            if (m.group(1) == '/') {
                if (!VOID_TAGS.contains(name)) {
                    out += '</' + name + '>';
                }
                continue;
            }
            out += '<' + name + safeAttributes(m.group(3)) + (VOID_TAGS.contains(name) ? '/>' : '>');
        }
        return out + escapeText(source.substring(last));
    }

    static String escapeText(String text) {
        // Keep entity references the editor wrote (&amp; &nbsp; &#39;), escape everything else that could start markup.
        return text.replaceAll('&(?!(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});)', '&amp;')
            .replace('<', '&lt;')
            .replace('>', '&gt;')
            .replace('"', '&quot;');
    }

    static String safeAttributes(String raw) {
        String out = '';
        if (String.isBlank(raw)) {
            return out;
        }
        Matcher m = ATTR.matcher(raw);
        while (m.find()) {
            String name = m.group(1).toLowerCase();
            String value = m.group(3) != null ? m.group(3) : (m.group(4) != null ? m.group(4) : m.group(5));
            if (value == null) {
                continue;
            }
            if (name == 'class' && CLASS_OK.matcher(value).matches()) {
                out += ' class="' + value.normalizeSpace() + '"';
            } else if (name == 'style') {
                String style = safeStyle(value);
                if (String.isNotBlank(style)) {
                    out += ' style="' + style + '"';
                }
            }
        }
        return out;
    }

    static String safeStyle(String value) {
        List<String> kept = new List<String>();
        for (String declaration : value.split(';')) {
            String property = declaration.substringBefore(':').trim().toLowerCase();
            String setting = declaration.substringAfter(':').trim();
            if (STYLE_OK.containsKey(property) && String.isNotBlank(setting) && STYLE_OK.get(property).matcher(setting).matches()) {
                kept.add(property + ':' + setting);
            }
        }
        return String.join(kept, ';');
    }

    // ---------- Signers ----------

    /** Set when the document is being generated for e-signature. Null for ordinary documents. */
    public DocBuilderSignProvider signProvider;

    /**
     * The template's signers with their name and email worked out for this record.
     * Each is defined as { "role", "name", "email" }, where name and email may be typed text or field tokens.
     */
    /** Signers supplied by the sender, used in place of the template's own when present. */
    public List<DocBuilderSign.Signer> signerOverrides;

    public List<DocBuilderSign.Signer> resolveSigners() {
        if (signerOverrides != null && !signerOverrides.isEmpty()) {
            return signerOverrides;
        }
        List<DocBuilderSign.Signer> signers = new List<DocBuilderSign.Signer>();
        Integer position = 0;
        for (Object s : asList(body.get('signers'))) {
            Map<String, Object> definition = (Map<String, Object>) s;
            String role = definition.get('role') == null ? '' : String.valueOf(definition.get('role')).trim();
            String source = (String) definition.get('source');

            // Everyone in a related list, for example each Contact Role on an opportunity.
            if (String.isNotBlank(source)) {
                for (SObject row : rowsFor(source, definition.get('filter'))) {
                    if (signers.size() >= MAX_SIGNERS) {
                        break;
                    }
                    Object email = resolve(row, (String) definition.get('emailField'));
                    if (email == null || String.isBlank(String.valueOf(email))) {
                        // Someone with no email address cannot sign electronically, so they are left out.
                        continue;
                    }
                    position++;
                    DocBuilderSign.Signer signer = new DocBuilderSign.Signer();
                    signer.role = String.isBlank(role) ? 'Signer ' + position : role;
                    String nameField = String.isBlank((String) definition.get('nameField')) ? 'Name' : (String) definition.get('nameField');
                    signer.name = formatValue(row, nameField, null);
                    signer.email = String.valueOf(email).trim();
                    signer.routingOrder = position;
                    signers.add(signer);
                }
                continue;
            }

            String name = (String) definition.get('name');
            String email = (String) definition.get('email');
            if (String.isBlank(role) && String.isBlank(name) && String.isBlank(email)) {
                // An empty row left in the designer is not a signer.
                continue;
            }
            position++;
            DocBuilderSign.Signer signer = new DocBuilderSign.Signer();
            signer.role = String.isBlank(role) ? 'Signer ' + position : role;
            signer.name = mergeText(name, record, false).trim();
            signer.email = mergeText(email, record, false).trim();
            signer.routingOrder = position;
            signers.add(signer);
        }
        return signers;
    }

    static final Integer MAX_SIGNERS = 50;

    // ---------- Email and signature request wording set on the template ----------

    public static final List<String> MESSAGE_KEYS = new List<String>{ 'emailSubject', 'emailBody', 'signSubject', 'signMessage' };

    Map<String, Object> messages() {
        Object value = body.get('messages');
        return value instanceof Map<String, Object> ? (Map<String, Object>) value : new Map<String, Object>();
    }

    /** One of the template's messages with fields and conditions filled in for this record, or null if it has none. */
    public String message(String key) {
        String text = (String) messages().get(key);
        if (String.isBlank(text) || record == null) {
            return null;
        }
        String merged = mergeText(text, record, false).trim();
        return String.isBlank(merged) ? null : merged;
    }

    // ---------- Page setup ----------

    public Map<String, Object> pageSettings() {
        Object page = body.get('page');
        return page instanceof Map<String, Object> ? (Map<String, Object>) page : new Map<String, Object>();
    }

    /** One of the page sections: header, footer or watermark. Never null. */
    public Map<String, Object> section(String key) {
        Object part = pageSettings().get(key);
        return part instanceof Map<String, Object> ? (Map<String, Object>) part : new Map<String, Object>();
    }

    static String escape(String value, Boolean html) {
        return html && value != null ? value.escapeHtml4() : value;
    }

    // ---------- Rules ----------

    /**
     * Evaluates a rule: { "logic": "1 AND (2 OR 3)", "conditions": [ { "field", "op", "value" } ] }.
     * logic may be omitted or AND (all), OR (any), or an expression over the condition numbers.
     * Pass a logKey for block-level rules so the outcome is kept in the audit snapshot.
     */
    public Boolean passes(Object ruleObj, SObject source, String logKey) {
        if (ruleObj == null) {
            return true;
        }
        Map<String, Object> rule = (Map<String, Object>) ruleObj;
        List<Object> conditions = asList(rule.get('conditions'));
        if (conditions.isEmpty()) {
            return true;
        }

        List<Boolean> results = new List<Boolean>();
        List<Object> detail = new List<Object>();
        for (Object c : conditions) {
            Map<String, Object> condition = (Map<String, Object>) c;
            String field = (String) condition.get('field');
            String op = condition.get('op') == null ? 'eq' : (String) condition.get('op');
            String expected = condition.get('value') == null ? '' : String.valueOf(condition.get('value'));
            Boolean isCalc = field.startsWith('calc:');
            Boolean isApex = field.startsWith('apex:');
            Object actual;
            if (isCalc) {
                actual = calcValue(field.substring(5));
            } else if (isApex) {
                actual = apexValue(field.substring(5));
            } else {
                actual = resolve(source, field);
            }
            if (!isCalc && !isApex && source === record) {
                usedValues.put(field, actual);
            }
            Boolean result = compare(actual, op, expected);
            results.add(result);
            detail.add(new Map<String, Object>{ 'field' => field, 'op' => op, 'value' => expected, 'actual' => actual, 'result' => result });
        }

        String logic = (String) rule.get('logic');
        Boolean outcome;
        if (String.isBlank(logic) || logic.trim().equalsIgnoreCase('AND')) {
            outcome = !results.contains(false);
        } else if (logic.trim().equalsIgnoreCase('OR')) {
            outcome = results.contains(true);
        } else {
            outcome = new LogicParser(logic, results).parse();
        }
        if (logKey != null) {
            logicLog.put(logKey, new Map<String, Object>{ 'logic' => String.isBlank(logic) ? 'AND' : logic, 'conditions' => detail, 'result' => outcome });
        }
        return outcome;
    }

    static Boolean compare(Object actual, String op, String expected) {
        String o = op.toLowerCase();
        Boolean isBlank = actual == null || String.valueOf(actual) == '';
        if (o == 'blank') {
            return isBlank;
        }
        if (o == 'notblank') {
            return !isBlank;
        }
        if (isBlank) {
            return o == 'ne';
        }
        String want = expected == null ? '' : expected.trim();
        if (actual instanceof Date || actual instanceof Datetime) {
            // Dates compare as dates (values typed as YYYY-MM-DD); a date-time compares by its day.
            Date a = actual instanceof Date ? (Date) actual : ((Datetime) actual).date();
            Date b;
            try {
                b = Date.valueOf(want.left(10));
            } catch (Exception e) {
                return o == 'ne';
            }
            Map<String, Boolean> outcomes = new Map<String, Boolean>{ 'eq' => a == b, 'ne' => a != b, 'gt' => a > b, 'ge' => a >= b, 'lt' => a < b, 'le' => a <= b };
            return outcomes.containsKey(o) ? outcomes.get(o) : false;
        }
        if (actual instanceof Decimal || actual instanceof Integer || actual instanceof Long || actual instanceof Double) {
            Decimal a = Decimal.valueOf(String.valueOf(actual));
            Decimal b;
            try {
                b = Decimal.valueOf(want);
            } catch (Exception e) {
                return o == 'ne';
            }
            if (o == 'eq') {
                return a == b;
            }
            if (o == 'ne') {
                return a != b;
            }
            if (o == 'gt') {
                return a > b;
            }
            if (o == 'ge') {
                return a >= b;
            }
            if (o == 'lt') {
                return a < b;
            }
            if (o == 'le') {
                return a <= b;
            }
            return false;
        }
        String actualText = String.valueOf(actual).toLowerCase();
        String wantText = want.toLowerCase();
        if (o == 'eq') {
            return actualText.equals(wantText);
        }
        if (o == 'ne') {
            return !actualText.equals(wantText);
        }
        if (o == 'contains') {
            return actualText.contains(wantText);
        }
        Integer cmp = actualText.compareTo(wantText);
        if (o == 'gt') {
            return cmp > 0;
        }
        if (o == 'ge') {
            return cmp >= 0;
        }
        if (o == 'lt') {
            return cmp < 0;
        }
        if (o == 'le') {
            return cmp <= 0;
        }
        return false;
    }

    /** Parses expressions such as 1 AND (2 OR NOT 3) over a list of condition results. */
    public class LogicParser {
        List<String> tokens = new List<String>();
        List<Boolean> results;
        Integer pos = 0;
        Boolean ok = true;
        String source;

        public LogicParser(String logic, List<Boolean> results) {
            this.results = results;
            this.source = logic;
            String upper = logic.toUpperCase();
            Matcher m = Pattern.compile('\\d+|AND|OR|NOT|\\(|\\)').matcher(upper);
            while (m.find()) {
                tokens.add(m.group());
            }
            if (String.isNotBlank(upper.replaceAll('\\d+|AND|OR|NOT|\\(|\\)|\\s+', ''))) {
                ok = false;
            }
        }

        public Boolean parse() {
            Boolean value = tokens.isEmpty() ? false : orExpr();
            if (tokens.isEmpty() || pos < tokens.size()) {
                ok = false;
            }
            if (!ok) {
                throw new DocBuilder.DocBuilderException('Rule logic cannot be read: ' + source);
            }
            return value;
        }

        // Nesting depth so far. Capped so a deeply bracketed rule fails cleanly instead of hitting the stack limit.
        Integer depth = 0;

        Boolean factor() {
            if (pos >= tokens.size() || depth >= MAX_NESTING) {
                ok = false;
                pos = tokens.size();
                return false;
            }
            String token = tokens[pos++];
            if (token == 'NOT') {
                depth++;
                Boolean negated = !factor();
                depth--;
                return negated;
            }
            if (token == '(') {
                depth++;
                Boolean grouped = orExpr();
                depth--;
                if (pos >= tokens.size() || tokens[pos++] != ')') {
                    ok = false;
                }
                return grouped;
            }
            if (!token.isNumeric()) {
                ok = false;
                return false;
            }
            Integer n = Integer.valueOf(token);
            if (n < 1 || n > results.size()) {
                ok = false;
                return false;
            }
            return results[n - 1];
        }

        Boolean andExpr() {
            Boolean value = factor();
            while (pos < tokens.size() && tokens[pos] == 'AND') {
                pos++;
                Boolean nextValue = factor();
                value = value && nextValue;
            }
            return value;
        }

        Boolean orExpr() {
            Boolean value = andExpr();
            while (pos < tokens.size() && tokens[pos] == 'OR') {
                pos++;
                Boolean nextValue = andExpr();
                value = value || nextValue;
            }
            return value;
        }
    }

    /**
     * Evaluates arithmetic for formula calculations, e.g. Amount * (1 - Discount__c / 100) or calc:Subtotal * 0.9.
     * Operands are numbers, fields on the source record (or its parents) and earlier calculations.
     */
    public class ExprParser {
        final Set<String> COMPARISONS = new Set<String>{ '=', '==', '!=', '<>', '<', '<=', '>', '>=' };
        final Set<String> FUNCTIONS = new Set<String>{ 'ROUND', 'ABS', 'CEILING', 'FLOOR', 'MIN', 'MAX', 'IF', 'AND', 'OR', 'NOT' };
        List<String> tokens = new List<String>();
        Integer pos = 0;
        String source;
        DocBuilderContext ctx;

        public ExprParser(String expression, DocBuilderContext ctx) {
            this.source = expression == null ? '' : expression;
            this.ctx = ctx;
            String tokenPattern = '\\d+(\\.\\d+)?|calc:[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_.]*|<=|>=|!=|<>|==|[-+*/(),<>=]';
            Matcher m = Pattern.compile(tokenPattern).matcher(source);
            while (m.find()) {
                tokens.add(m.group());
            }
            if (tokens.isEmpty() || String.isNotBlank(source.replaceAll(tokenPattern + '|\\s+', ''))) {
                fail();
            }
        }

        void fail() {
            throw new DocBuilder.DocBuilderException('Formula cannot be read: ' + source);
        }

        public Decimal evaluate() {
            Decimal value = comparison();
            if (pos < tokens.size()) {
                fail();
            }
            return value;
        }

        /** a = b, a != b, a < b and so on give 1 when true and 0 when false, for use in IF, AND and OR. */
        Decimal comparison() {
            Decimal value = sum();
            if (pos < tokens.size() && COMPARISONS.contains(tokens[pos])) {
                String op = tokens[pos++];
                Decimal other = sum();
                Boolean holds;
                if (op == '=' || op == '==') {
                    holds = value == other;
                } else if (op == '!=' || op == '<>') {
                    holds = value != other;
                } else if (op == '<') {
                    holds = value < other;
                } else if (op == '<=') {
                    holds = value <= other;
                } else if (op == '>') {
                    holds = value > other;
                } else {
                    holds = value >= other;
                }
                value = holds ? 1 : 0;
            }
            return value;
        }

        List<Decimal> arguments() {
            List<Decimal> args = new List<Decimal>();
            // The opening bracket has been read.
            if (pos < tokens.size() && tokens[pos] == ')') {
                pos++;
                return args;
            }
            Boolean more = true;
            while (more) {
                args.add(comparison());
                if (pos >= tokens.size()) {
                    fail();
                }
                String next = tokens[pos++];
                if (next == ')') {
                    more = false;
                } else if (next != ',') {
                    fail();
                }
            }
            return args;
        }

        Decimal call(String name, List<Decimal> args) {
            String fn = name.toUpperCase();
            Integer count = args.size();
            if (fn == 'ROUND' && (count == 1 || count == 2)) {
                return args[0].setScale(count == 2 ? Math.max(0, Math.min(10, args[1].intValue())) : 0, RoundingMode.HALF_UP);
            }
            if (fn == 'ABS' && count == 1) {
                return args[0].abs();
            }
            if (fn == 'CEILING' && count == 1) {
                return args[0].round(System.RoundingMode.CEILING);
            }
            if (fn == 'FLOOR' && count == 1) {
                return args[0].round(System.RoundingMode.FLOOR);
            }
            if ((fn == 'MIN' || fn == 'MAX') && count > 0) {
                Decimal best = args[0];
                for (Decimal a : args) {
                    best = fn == 'MIN' ? (a < best ? a : best) : (a > best ? a : best);
                }
                return best;
            }
            if (fn == 'IF' && count == 3) {
                return args[0] != 0 ? args[1] : args[2];
            }
            if ((fn == 'AND' || fn == 'OR') && count > 0) {
                Boolean result = fn == 'AND';
                for (Decimal a : args) {
                    result = fn == 'AND' ? result && a != 0 : result || a != 0;
                }
                return result ? 1 : 0;
            }
            if (fn == 'NOT' && count == 1) {
                return args[0] == 0 ? 1 : 0;
            }
            if (FUNCTIONS.contains(fn)) {
                throw new DocBuilder.DocBuilderException('Formula function ' + fn + ' has the wrong number of values: ' + source);
            }
            throw new DocBuilder.DocBuilderException('Formula uses an unknown function ' + name + ': ' + source);
        }

        Decimal sum() {
            Decimal value = product();
            while (pos < tokens.size() && (tokens[pos] == '+' || tokens[pos] == '-')) {
                String op = tokens[pos++];
                Decimal nextValue = product();
                value = op == '+' ? value + nextValue : value - nextValue;
            }
            return value;
        }

        Decimal product() {
            Decimal value = unary();
            while (pos < tokens.size() && (tokens[pos] == '*' || tokens[pos] == '/')) {
                String op = tokens[pos++];
                Decimal nextValue = unary();
                if (op == '*') {
                    value = value * nextValue;
                } else {
                    value = nextValue == 0 ? 0 : value.divide(nextValue, 6, RoundingMode.HALF_UP);
                }
            }
            return value;
        }

        // Nesting depth so far. Every bracket, function call and leading minus passes through unary(), so capping
        // it here stops a deeply nested formula from hitting the stack limit, which cannot be caught.
        Integer depth = 0;

        Decimal unary() {
            if (++depth > MAX_NESTING) {
                throw new DocBuilder.DocBuilderException('Formula is nested too deeply: ' + source.left(200));
            }
            Decimal value;
            if (pos < tokens.size() && tokens[pos] == '-') {
                pos++;
                value = -unary();
            } else {
                value = operand();
            }
            depth--;
            return value;
        }

        Decimal operand() {
            if (pos >= tokens.size()) {
                fail();
            }
            String token = tokens[pos++];
            if (token == '(') {
                Decimal grouped = comparison();
                if (pos >= tokens.size() || tokens[pos++] != ')') {
                    fail();
                }
                return grouped;
            }
            if (token.left(1).isNumeric()) {
                return Decimal.valueOf(token);
            }
            if (pos < tokens.size() && tokens[pos] == '(' && !token.startsWith('calc:')) {
                pos++;
                return call(token, arguments());
            }
            if (token == ',' || COMPARISONS.contains(token)) {
                fail();
            }
            if (token.startsWith('calc:')) {
                String name = token.substring(5);
                if (ctx.textCalcs.containsKey(name)) {
                    throw new DocBuilder.DocBuilderException('Calculated value "' + name + '" is text, so a formula can\'t use it. Use it in text or in a rule instead.');
                }
                if (!ctx.calcs.containsKey(name)) {
                    throw new DocBuilder.DocBuilderException('Formula uses "' + name + '" before it is calculated. Move it above this formula.');
                }
                return ctx.calcs.get(name);
            }
            if (token == ')' || token == '+' || token == '*' || token == '/') {
                fail();
            }
            Object raw = ctx.resolve(ctx.record, token);
            ctx.usedValues.put(token, raw);
            if (raw == null) {
                return 0;
            }
            try {
                return Decimal.valueOf(String.valueOf(raw));
            } catch (Exception e) {
                throw new DocBuilder.DocBuilderException('Formula field "' + token + '" is not a number.');
            }
        }
    }

    // ---------- Audit snapshot ----------

    public String snapshotJson(String templateName, Decimal versionNumber) {
        Map<String, Object> listData = new Map<String, Object>();
        for (String rel : lists.keySet()) {
            List<Object> rows = new List<Object>();
            for (SObject row : lists.get(rel)) {
                Map<String, Object> values = new Map<String, Object>();
                for (String path : childFields.get(rel).values()) {
                    values.put(path, resolve(row, path));
                }
                rows.add(values);
            }
            listData.put(rel, rows);
        }

        Map<String, Object> snapshot = new Map<String, Object>{
            'template' => templateName,
            'templateVersion' => versionNumber,
            'generatedAt' => System.now(),
            'generatedBy' => UserInfo.getUserId(),
            'object' => baseObject,
            'recordId' => recordId,
            'values' => usedValues,
            'lists' => listData,
            'calculations' => allCalcValues(),
            'logic' => logicLog
        };
        String serialized = JSON.serializePretty(snapshot);
        if (serialized.length() > SNAPSHOT_LIMIT) {
            snapshot.put('lists', new Map<String, Object>());
            snapshot.put('listsOmitted', 'Row data was too large to store with this record.');
            serialized = JSON.serializePretty(snapshot);
        }
        return serialized.left(SNAPSHOT_LIMIT);
    }
}
