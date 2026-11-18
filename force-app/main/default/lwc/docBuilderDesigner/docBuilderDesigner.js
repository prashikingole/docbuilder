import { renderSafe } from 'c/docBuilderSafeHtml';
import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import listTemplates from '@salesforce/apex/DocBuilderDesignerController.listTemplates';
import createTemplate from '@salesforce/apex/DocBuilderDesignerController.createTemplate';
import loadTemplate from '@salesforce/apex/DocBuilderDesignerController.loadTemplate';
import saveDraft from '@salesforce/apex/DocBuilderDesignerController.saveDraft';
import activateTemplate from '@salesforce/apex/DocBuilderDesignerController.activate';
import describeObject from '@salesforce/apex/DocBuilderDesignerController.describeObject';
import previewBody from '@salesforce/apex/DocBuilderDesignerController.preview';
import checkBody from '@salesforce/apex/DocBuilderDesignerController.check';
import getTranslations from '@salesforce/apex/DocBuilderDesignerController.getTranslations';
import saveTranslations from '@salesforce/apex/DocBuilderDesignerController.saveTranslations';
import listProviders from '@salesforce/apex/DocBuilderDesignerController.listProviders';
import testProvider from '@salesforce/apex/DocBuilderDesignerController.testProvider';
import calcValues from '@salesforce/apex/DocBuilderDesignerController.calcValues';
import listVersions from '@salesforce/apex/DocBuilderDesignerController.listVersions';
import makeVersionLive from '@salesforce/apex/DocBuilderDesignerController.makeVersionLive';
import copyVersionToDraft from '@salesforce/apex/DocBuilderDesignerController.copyVersionToDraft';
import LightningConfirm from 'lightning/confirm';

const TOKEN = /\{\{\s*([^}|]+?)\s*(?:\|\s*([A-Za-z]+)\s*)?\}\}/g;
const TYPE_LABELS = { heading: 'Heading', text: 'Text', table: 'Table', terms: 'Terms', image: 'Image', signature: 'Signature', pagebreak: 'Page break' };
const FILE_URL = '/sfc/servlet.shepherd/version/download/';
const NOISE_LISTS = /(History|Histories|Feed|Feeds|Share|Shares|ChangeEvent|Tag|Tags)$|^(ActivityHistories|OpenActivities|AttachedContentDocuments|AttachedContentNotes|CombinedAttachments|ContentDocumentLinks|ContentDistributions|Attachments|Notes|NotesAndAttachments|Emails|EmailMessageRelations|EventRelations|TaskRelations|ProcessInstances|ProcessSteps|ProcessExceptions|RecordActions|RecordActionHistories|RecordAssociatedGroups|TopicAssignments|FeedSubscriptionsForEntity|UserRecordAccess|FlowOrchestrationWorkItems|FlowExecutionErrorEvents|NetworkActivityAudits|CollaborationGroupRecords|DuplicateRecordItems|PendingServiceRoutings|MessagingSessions|SurveySubjectEntities|ContactRequests|AIRecordInsights|AIInsightValues|ContentVersions|LookedUpFromActivities|Personas|WorkOrders|ServiceAppointments|Swarms|SwarmMembers|ConversationEntries|GptPromptEvents|AppUsageAssignments|ScorecardAssociations|AccountUserTerritory2Views)$/;
const PAGE_SHAPES = { a4: 1.414, letter: 1.294, legal: 1.647 };
const PAGE_PADDING = { narrow: '1.5rem', normal: '2.5rem', wide: '3.75rem' };
const OP_LABELS = { eq: '=', ne: '≠', gt: '>', ge: '≥', lt: '<', le: '≤', contains: 'contains', blank: 'is blank', notBlank: 'is not blank' };
const NUMERIC_TYPES = ['Currency', 'Double', 'Integer', 'Percent', 'Long'];
const PICKER_LIMIT = 150;
const OP_WORDS = { eq: 'is', ne: 'is not', gt: 'is more than', ge: 'is at least', lt: 'is less than', le: 'is at most', contains: 'contains', blank: 'is empty', notBlank: 'has a value' };
const MAX_ROW = 4;
const MIN_SPAN = 10;
// Formula functions, as the server's formula reader understands them.
const FX_FUNCTIONS = [
    { name: 'ROUND', hint: 'ROUND(value, places): round to decimal places' },
    { name: 'IF', hint: 'IF(test, then, else): e.g. IF(Amount > 1000, 0.1, 0)' },
    { name: 'MIN', hint: 'MIN(a, b, …): the smallest' },
    { name: 'MAX', hint: 'MAX(a, b, …): the largest' },
    { name: 'ABS', hint: 'ABS(value): without the minus sign' },
    { name: 'CEILING', hint: 'CEILING(value): round up' },
    { name: 'FLOOR', hint: 'FLOOR(value): round down' },
    { name: 'AND', hint: 'AND(test, test, …): all are true' },
    { name: 'OR', hint: 'OR(test, test, …): any is true' },
    { name: 'NOT', hint: 'NOT(test): the opposite' }
];
const FX_TOKEN = new RegExp('\\d+(?:\\.\\d+)?|calc:[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_.]*|<=|>=|!=|<>|==|[-+*\\/(),<>=]|\\s+|[\\s\\S]', 'g');
const FX_OPERATOR = new RegExp('^(<=|>=|!=|<>|==|[-+*\\/(),<>=])$');
const FX_SHOW = { '*': '×', '/': '÷', '-': '−', '<=': '≤', '>=': '≥', '!=': '≠', '<>': '≠', '==': '=' };

export default class DocBuilderDesigner extends LightningElement {
    templates = [];
    templateId;
    tpl;
    name = '';
    fileNamePattern = '';
    languages = '';
    body = { blocks: [], calculations: [] };
    selectedId;
    mode = 'design';
    dirty = false;
    busy = false;
    health;

    objects = {};
    pickerPath = [];
    tableObject;
    search = '';
    focus = { prop: 'text' };

    showNew = false;
    newName = '';
    newObject = 'Opportunity';

    previewRecordId;
    previewLanguage = '';
    previewHtml;
    previewError;
    renderedPreview;

    transLanguage = '';
    transParts = [];

    showAllLists = false;
    imageFormats = ['.png', '.jpg', '.jpeg', '.gif'];
    pageSizeOptions = [
        { label: 'A4', value: 'A4' },
        { label: 'US Letter', value: 'Letter' },
        { label: 'US Legal', value: 'Legal' }
    ];
    orientationOptions = [
        { label: 'Portrait', value: 'portrait' },
        { label: 'Landscape', value: 'landscape' }
    ];
    marginOptions = [
        { label: 'Narrow', value: 'narrow' },
        { label: 'Normal', value: 'normal' },
        { label: 'Wide', value: 'wide' }
    ];
    alignOptions = [
        { label: 'Left', value: '' },
        { label: 'Centre', value: 'center' },
        { label: 'Right', value: 'right' }
    ];
    levelOptions = [
        { label: 'Large', value: '1' },
        { label: 'Medium', value: '2' },
        { label: 'Small', value: '3' }
    ];
    formatOptions = [
        { label: 'Automatic', value: '' },
        { label: 'Currency', value: 'currency' },
        { label: 'Number', value: 'number' },
        { label: 'Percent', value: 'percent' },
        { label: 'Date', value: 'date' },
        { label: 'UPPERCASE', value: 'upper' },
        { label: 'lowercase', value: 'lower' }
    ];
    calcTypeOptions = [
        { label: 'Count of rows', value: 'count' },
        { label: 'Sum', value: 'sum' },
        { label: 'Average', value: 'avg' },
        { label: 'Lowest', value: 'min' },
        { label: 'Highest', value: 'max' },
        { label: 'Formula', value: 'formula' }
    ];
    directionOptions = [
        { label: 'Ascending', value: 'ASC' },
        { label: 'Descending', value: 'DESC' }
    ];
    modeOptions = [
        { label: 'Design', value: 'design' },
        { label: 'Preview', value: 'preview' },
        { label: 'Translate', value: 'translate' }
    ];

    connectedCallback() {
        this.refreshTemplates();
        this.loadProviders();
    }

    renderedCallback() {
        const host = this.template.querySelector('.preview-body');
        if (host && this.renderedPreview !== this.previewHtml) {
            renderSafe(host, this.previewHtml);
            this.renderedPreview = this.previewHtml;
        }
        // After a formula suggestion is picked, put the caret back where typing continues.
        if (this.pendingCaret) {
            const input = this.template.querySelector(`input.fx-input[data-index="${this.pendingCaret.index}"]`);
            if (input) {
                input.focus();
                input.setSelectionRange(this.pendingCaret.pos, this.pendingCaret.pos);
            }
            this.pendingCaret = undefined;
        }
    }

    disconnectedCallback() {
        clearTimeout(this.calcTimer);
    }

    // ---------- Helpers ----------

    uid() {
        return 'b' + Math.random().toString(36).slice(2, 8);
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant: variant || 'success' }));
    }

    messageOf(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        return error && error.message ? error.message : 'Something went wrong.';
    }

    async run(work) {
        this.busy = true;
        try {
            await work();
        } catch (e) {
            this.toast('That did not work', this.messageOf(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    mutate(change) {
        const body = JSON.parse(JSON.stringify(this.body));
        change(body);
        this.pruneAutoConditions(body);
        this.body = body;
        this.dirty = true;
        this.health = undefined;
        if (this.settingsPanel === 'calc' && !this.selectedId) {
            this.scheduleCalcRefresh();
        }
    }

    /** Conditions made for one conditional part of a text are removed once no text uses them. */
    pruneAutoConditions(body) {
        if (!Array.isArray(body.conditions) || !body.conditions.some((c) => c.auto)) {
            return;
        }
        const others = JSON.stringify({ ...body, conditions: [] });
        body.conditions = body.conditions.filter((c) => !c.auto || others.includes('cond:' + c.name + '}}'));
    }

    blockIn(body) {
        return body.blocks.find((b) => b.id === this.selectedId);
    }

    valueOf(event) {
        return event.target.type === 'checkbox' ? event.target.checked : event.detail.value;
    }

    async ensureObject(objectName) {
        if (!objectName) {
            return null;
        }
        const key = objectName.toLowerCase();
        if (!this.objects[key]) {
            const info = await describeObject({ objectName });
            this.objects = { ...this.objects, [key]: info };
        }
        return this.objects[key];
    }

    infoFor(objectName) {
        return objectName ? this.objects[objectName.toLowerCase()] : null;
    }

    /** Works out which object a list holds, including lists on a related record such as Account.Contacts. */
    async resolveListObject(source) {
        if (!source || !this.tpl) {
            return null;
        }
        const parts = source.split('.');
        let objectName = this.tpl.baseObject;
        for (let i = 0; i < parts.length - 1; i++) {
            // eslint-disable-next-line no-await-in-loop
            const info = await this.ensureObject(objectName);
            const lookup = info && info.fields.find((f) => f.relationshipName === parts[i]);
            if (!lookup) {
                return null;
            }
            objectName = lookup.referenceTo;
        }
        const owner = await this.ensureObject(objectName);
        const child = owner && owner.children.find((c) => c.name === parts[parts.length - 1]);
        if (!child) {
            return null;
        }
        await this.ensureObject(child.childObject);
        return child.childObject;
    }

    segments(text) {
        const result = [];
        if (!text) {
            return result;
        }
        let last = 0;
        let match;
        let n = 0;
        TOKEN.lastIndex = 0;
        while ((match = TOKEN.exec(text)) !== null) {
            if (match.index > last) {
                result.push({ key: n++, text: text.substring(last, match.index), cls: 'plain' });
            }
            const path = match[1].trim();
            const lower = path.toLowerCase();
            if (lower.startsWith('#if ') || lower === 'else' || lower === '/if') {
                // Condition markers show as small labels, so the author can see what is conditional.
                let label = 'end if';
                if (lower === 'else') {
                    label = 'otherwise';
                } else if (lower.startsWith('#if ')) {
                    let target = path.substring(4).trim();
                    const negate = target.toLowerCase().startsWith('not ');
                    if (negate) {
                        target = target.substring(4).trim();
                    }
                    const named = target.startsWith('cond:');
                    const name = named ? target.substring(5) : target.split('.').join(' › ');
                    label = 'if ' + name + (named ? '' : negate ? ' is empty' : ' has a value');
                }
                result.push({ key: n++, text: label, cls: 'chip chip-if' });
                last = match.index + match[0].length;
                continue;
            }
            const isCalc = path.startsWith('calc:');
            const label = (isCalc ? path.substring(5) : path.split('.').join(' › ')) + (match[2] ? ' · ' + match[2] : '');
            result.push({ key: n++, text: label, cls: isCalc ? 'chip chip-calc' : 'chip' });
            last = match.index + match[0].length;
        }
        if (last < text.length) {
            result.push({ key: n++, text: text.substring(last), cls: 'plain' });
        }
        return result;
    }

    // ---------- Conditional parts of a text (numbered badges) ----------

    /**
     * Splits a text into pieces for the canvas. Each {{#if}} … {{/if}} becomes a numbered conditional part:
     * its pieces are tinted, a badge with its number follows it, and the key under the block says in plain
     * words when it prints. Fields outside a part can be clicked to make them conditional.
     */
    textView(text, blockId) {
        const segs = [];
        const legend = [];
        if (!text) {
            return { segs, legend };
        }
        const focusNum = this.focusPart && this.focusPart.blockId === blockId && this.focusPart.kind === 'section' ? this.focusPart.num : null;
        const focusStart = this.focusPart && this.focusPart.blockId === blockId && this.focusPart.kind === 'field' ? this.focusPart.start : null;
        const re = new RegExp(TOKEN.source, 'g');
        const stack = [];
        let num = 0;
        let last = 0;
        let n = 0;
        let m;
        const top = () => stack[stack.length - 1];
        const tint = (base) => {
            const open = top();
            if (!open) {
                return base;
            }
            return base + (open.inElse ? ' in-else' : ' in-cond') + (stack.some((s) => s.num === focusNum) ? ' part-focus' : '');
        };
        const pushText = (s) => {
            if (s) {
                segs.push({ key: n++, text: s, cls: tint('plain'), kind: stack.length ? 'section' : '', num: stack.length ? top().num : undefined });
            }
        };
        while ((m = re.exec(text)) !== null) {
            pushText(text.substring(last, m.index));
            last = m.index + m[0].length;
            const path = m[1].trim();
            const lower = path.toLowerCase();
            if (lower.startsWith('#if ')) {
                let target = path.substring(4).trim();
                const negate = target.toLowerCase().startsWith('not ');
                if (negate) {
                    target = target.substring(4).trim();
                }
                num++;
                stack.push({ num, inElse: false });
                legend.push({ key: 'l' + num, num, label: String(num), text: this.sectionWords(target, negate), cls: 'legend-item' + (num === focusNum ? ' on' : '') });
            } else if (lower === 'else') {
                const open = top();
                if (open) {
                    segs.push({ key: n++, text: String(open.num), cls: 'cond-badge', kind: 'section', num: open.num });
                    open.inElse = true;
                }
            } else if (lower === '/if') {
                const open = stack.pop();
                if (open) {
                    segs.push({ key: n++, text: open.inElse ? 'otherwise' : String(open.num), cls: open.inElse ? 'cond-badge else' : 'cond-badge', kind: 'section', num: open.num });
                }
            } else {
                const isCalc = path.startsWith('calc:');
                const label = (isCalc ? path.substring(5) : path.split('.').join(' › ')) + (m[2] ? ' · ' + m[2] : '');
                const inSection = stack.length > 0;
                const base = isCalc ? 'chip chip-calc' : 'chip';
                segs.push({
                    key: n++,
                    text: label,
                    cls: inSection ? tint(base) : base + ' pickable' + (m.index === focusStart ? ' part-focus' : ''),
                    kind: inSection ? 'section' : 'field',
                    num: inSection ? top().num : undefined,
                    start: m.index,
                    end: last,
                    path
                });
            }
        }
        pushText(text.substring(last));
        return { segs, legend };
    }

    /** Where one numbered conditional part sits in a text, by character positions. */
    findSection(text, wanted) {
        const re = new RegExp(TOKEN.source, 'g');
        const stack = [];
        let num = 0;
        let m;
        while ((m = re.exec(text || '')) !== null) {
            const path = m[1].trim();
            const lower = path.toLowerCase();
            if (lower.startsWith('#if ')) {
                let target = path.substring(4).trim();
                const negate = target.toLowerCase().startsWith('not ');
                if (negate) {
                    target = target.substring(4).trim();
                }
                num++;
                stack.push({ num, target, negate, openStart: m.index, openEnd: m.index + m[0].length });
            } else if (lower === 'else') {
                const open = stack[stack.length - 1];
                if (open) {
                    open.elseStart = m.index;
                    open.elseEnd = m.index + m[0].length;
                }
            } else if (lower === '/if') {
                const open = stack.pop();
                if (open && open.num === wanted) {
                    open.closeStart = m.index;
                    open.closeEnd = m.index + m[0].length;
                    open.ifEnd = open.elseStart !== undefined ? open.elseStart : open.closeStart;
                    open.ifText = text.substring(open.openEnd, open.ifEnd);
                    open.elseText = open.elseEnd !== undefined ? text.substring(open.elseEnd, open.closeStart) : '';
                    return open;
                }
            }
        }
        return null;
    }

    namedCondition(name) {
        return (this.body.conditions || []).find((c) => (c.name || '').toLowerCase() === (name || '').toLowerCase());
    }

    sectionWords(target, negate) {
        if (target.startsWith('cond:')) {
            const name = target.substring(5).trim();
            const condition = this.namedCondition(name);
            if (!condition) {
                return `Condition "${name}" does not exist. Click to set when this part prints.`;
            }
            const words = this.ruleWords(condition.rule) || 'Always printed: no conditions yet';
            const text = condition.auto ? words : `${name}: ${words}`;
            return negate ? 'Not (' + text + ')' : text;
        }
        return `${this.fieldLabel(target)} ${negate ? 'is empty' : 'has a value'}`;
    }

    /** A rule in plain words, e.g. "City has a value and City is not Delhi". */
    ruleWords(rule) {
        if (!rule || !Array.isArray(rule.conditions) || !rule.conditions.length) {
            return '';
        }
        const parts = rule.conditions.map((c) => {
            const op = OP_WORDS[c.op] || c.op;
            const value = c.op === 'blank' || c.op === 'notBlank' ? '' : ' ' + (c.value === '' || c.value == null ? '(empty)' : c.value);
            return `${this.fieldLabel(c.field)} ${op}${value}`;
        });
        const logic = (rule.logic || '').trim();
        if (!logic || logic.toUpperCase() === 'AND') {
            return parts.join(' and ');
        }
        if (logic.toUpperCase() === 'OR') {
            return parts.join(' or ');
        }
        return parts.map((p, i) => `(${i + 1}) ${p}`).join(', ') + '. Combined as ' + logic;
    }

    /** A field path as people read it: labels instead of API names where they are known. */
    fieldLabel(path) {
        if (!path) {
            return '(no field)';
        }
        if (path.startsWith('calc:')) {
            return path.substring(5);
        }
        let info = this.tpl ? this.infoFor(this.tpl.baseObject) : null;
        const parts = path.split('.');
        const labels = [];
        for (let i = 0; i < parts.length; i++) {
            if (!info) {
                labels.push(parts[i]);
                continue;
            }
            const name = parts[i].toLowerCase();
            if (i < parts.length - 1) {
                const lookup = info.fields.find((f) => (f.relationshipName || '').toLowerCase() === name);
                labels.push(lookup ? lookup.label.replace(/ ID$/, '') : parts[i]);
                info = lookup ? this.infoFor(lookup.referenceTo) : null;
            } else {
                const field = info.fields.find((f) => f.name.toLowerCase() === name);
                labels.push(field ? field.label : parts[i]);
            }
        }
        return labels.join(' › ');
    }

    ruleSummary(rule) {
        if (!rule || !rule.conditions || !rule.conditions.length) {
            return '';
        }
        const parts = rule.conditions.map((c, i) => `${i + 1}: ${c.field} ${OP_LABELS[c.op] || c.op} ${c.value == null ? '' : c.value}`.trim());
        return 'Show only if ' + parts.join('; ') + (rule.conditions.length > 1 ? ' · logic ' + (rule.logic || 'AND') : '');
    }

    // ---------- Template list and lifecycle ----------

    async refreshTemplates() {
        await this.run(async () => {
            this.templates = await listTemplates();
        });
    }

    get templateOptions() {
        return this.templates.map((t) => ({ label: `${t.Name} (${t.Base_Object__c}, ${t.Status__c})`, value: t.Id }));
    }

    get hasTemplate() {
        return !!this.tpl;
    }

    get noTemplate() {
        return !this.tpl;
    }

    get statusLabel() {
        if (!this.tpl) {
            return '';
        }
        const editing = this.tpl.versionStatus === 'Draft' ? `Draft version ${this.tpl.versionNumber}` : `Version ${this.tpl.versionNumber} is active`;
        const live = this.tpl.versionStatus === 'Draft' && this.tpl.activeVersionNumber ? ` · version ${this.tpl.activeVersionNumber} is live` : '';
        return editing + live + (this.dirty ? ' · unsaved changes' : '');
    }

    handleTemplateChange(event) {
        this.openTemplate(event.detail.value);
    }

    async openTemplate(templateId) {
        await this.run(async () => {
            this.apply(await loadTemplate({ templateId }));
            await this.ensureObject(this.tpl.baseObject);
        });
    }

    apply(state) {
        this.tpl = state;
        this.templateId = state.templateId;
        this.name = state.name || '';
        this.fileNamePattern = state.fileNamePattern || '';
        this.languages = state.languages || '';
        let body;
        try {
            body = JSON.parse(state.bodyJson || '{}');
        } catch (e) {
            body = {};
        }
        body.blocks = Array.isArray(body.blocks) ? body.blocks : [];
        body.calculations = Array.isArray(body.calculations) ? body.calculations : [];
        body.page = body.page && typeof body.page === 'object' ? body.page : {};
        body.signers = Array.isArray(body.signers) ? body.signers : [];
        body.conditions = Array.isArray(body.conditions) ? body.conditions : [];
        body.blocks.forEach((b) => {
            b.id = b.id || this.uid();
            (b.items || []).forEach((item) => {
                item.id = item.id || this.uid();
            });
        });
        this.body = body;
        this.selectedId = undefined;
        this.pickerPath = [];
        this.tableObject = undefined;
        this.dirty = false;
        this.health = undefined;
        this.previewHtml = undefined;
        this.previewError = undefined;
        this.transParts = [];
        // Saving, activating or switching template changes the version list.
        this.versions = [];
        if (this.settingsPanel === 'versions') {
            this.loadVersions();
        }
    }

    toggleNew() {
        this.showNew = !this.showNew;
    }

    // ---------- Import and export ----------

    showImport = false;

    handleOpenImport() {
        this.showImport = true;
        this.showNew = false;
    }

    handleCloseImport() {
        this.showImport = false;
    }

    async handleImported(event) {
        this.showImport = false;
        await this.run(async () => {
            this.apply(event.detail.state);
            this.templates = await listTemplates();
            await this.ensureObject(this.tpl.baseObject);
            this.mode = 'design';
            // Show straight away whether every matched field exists and is readable in this org.
            const problem = await checkBody({ bodyJson: JSON.stringify(this.body), baseObject: this.tpl.baseObject });
            this.health = problem ? { ok: false, text: 'Imported as a draft. ' + problem } : { ok: true, text: 'Imported as a draft. Every field it uses exists and is readable.' };
            this.toast('Template imported', 'Review it, add any logos or images, then Activate when it is ready.');
        });
    }

    /** Downloads the template as it is on screen (unsaved changes included), for importing into another org. */
    handleExport() {
        const data = {
            format: 'docbuilder-template',
            formatVersion: 1,
            name: this.name,
            baseObject: this.tpl.baseObject,
            fileNamePattern: this.fileNamePattern || '',
            languages: this.languages || '',
            exportedFromVersion: this.tpl.versionNumber,
            body: this.body
        };
        const link = document.createElement('a');
        link.href = 'data:application/json;charset=utf-8,' + encodeURIComponent(JSON.stringify(data, null, 2));
        link.download = (this.name || 'template').replace(/[^\w\- ]+/g, '').trim() + '.docbuilder.json';
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        this.toast('Template exported', 'Import the file in another org with Import. Translations and images are not included.');
    }

    handleNewField(event) {
        this[event.target.dataset.field] = event.detail.value;
    }

    async handleCreate() {
        await this.run(async () => {
            const state = await createTemplate({ name: this.newName, baseObject: this.newObject });
            this.templates = await listTemplates();
            this.apply(state);
            await this.ensureObject(this.tpl.baseObject);
            this.showNew = false;
            this.newName = '';
            this.toast('Template created', 'Add blocks from the toolbar, then save.');
        });
    }

    handleSetting(event) {
        this[event.target.dataset.field] = event.detail.value;
        this.dirty = true;
    }

    async save() {
        const state = await saveDraft({
            templateId: this.templateId,
            name: this.name,
            fileNamePattern: this.fileNamePattern,
            languages: this.languages,
            bodyJson: JSON.stringify(this.body)
        });
        const selected = this.selectedId;
        const path = this.pickerPath;
        const tableObject = this.tableObject;
        this.apply(state);
        this.selectedId = selected;
        this.pickerPath = path;
        this.tableObject = tableObject;
        this.templates = await listTemplates();
    }

    async handleSave() {
        await this.run(async () => {
            await this.save();
            this.toast('Draft saved', `Version ${this.tpl.versionNumber} is saved as a draft. People keep using the active version until you activate.`);
        });
    }

    async handleActivate() {
        await this.run(async () => {
            if (this.dirty || this.tpl.versionStatus !== 'Draft') {
                await this.save();
            }
            this.apply(await activateTemplate({ templateId: this.templateId }));
            this.templates = await listTemplates();
            this.toast('Template activated', `Version ${this.tpl.versionNumber} is now live.`);
        });
    }

    async handleCheck() {
        await this.run(async () => {
            const problem = await checkBody({ bodyJson: JSON.stringify(this.body), baseObject: this.tpl.baseObject });
            this.health = problem ? { ok: false, text: problem } : { ok: true, text: 'Every field this template uses exists and is readable.' };
        });
    }

    get healthClass() {
        return this.health && this.health.ok ? 'health ok' : 'health bad';
    }

    // ---------- Modes ----------

    get isDesign() {
        return this.mode === 'design';
    }

    get isPreview() {
        return this.mode === 'preview';
    }

    get isTranslate() {
        return this.mode === 'translate';
    }

    handleModeClick(event) {
        this.mode = event.currentTarget.dataset.mode;
        this.renderedPreview = undefined;
        if (this.mode === 'preview' && this.previewRecordId) {
            this.refreshPreview();
        }
    }

    get modeButtons() {
        return this.modeOptions.map((m) => ({
            ...m,
            pressed: m.value === this.mode ? 'true' : 'false',
            cls: m.value === this.mode ? 'seg-btn on' : 'seg-btn'
        }));
    }

    get versionChip() {
        if (!this.tpl || !this.tpl.versionNumber) {
            return '';
        }
        return `v${this.tpl.versionNumber} ${this.tpl.versionStatus === 'Draft' ? 'draft' : 'live'}`;
    }

    get savedLabel() {
        return this.dirty ? 'Unsaved changes' : 'Saved';
    }

    get savedDotCls() {
        return this.dirty ? 'dot warn' : 'dot';
    }

    // ---------- Right-hand panel ----------

    panelTab = 'settings';
    settingsPanel = 'template';

    get panelTabs() {
        return [
            { label: 'Settings', value: 'settings' },
            { label: 'Fields', value: 'fields' }
        ].map((t) => ({ ...t, pressed: t.value === this.panelTab ? 'true' : 'false', cls: t.value === this.panelTab ? 'seg-btn on' : 'seg-btn' }));
    }

    get showSettings() {
        return this.panelTab === 'settings';
    }

    get showFields() {
        return this.panelTab === 'fields';
    }

    handlePanelTab(event) {
        this.panelTab = event.currentTarget.dataset.tab;
    }

    /** The bar under the page opens one template-level section at a time. */
    handleDock(event) {
        this.handleDeselect();
        this.settingsPanel = event.currentTarget.dataset.panel;
        this.panelTab = 'settings';
        if (this.settingsPanel === 'calc') {
            this.refreshCalcValues();
        }
        if (this.settingsPanel === 'versions') {
            this.loadVersions();
        }
    }

    // ---------- Versions ----------

    versions = [];

    get isPanelVersions() {
        return this.settingsPanel === 'versions';
    }

    async loadVersions() {
        if (!this.templateId) {
            return;
        }
        try {
            this.versions = await listVersions({ templateId: this.templateId });
        } catch (e) {
            this.toast('Versions could not be loaded', this.messageOf(e), 'error');
        }
    }

    formatWhen(value) {
        if (!value) {
            return '';
        }
        try {
            return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value));
        } catch (e) {
            return String(value);
        }
    }

    get hasDraftVersion() {
        return this.versions.some((v) => v.status === 'Draft');
    }

    get versionRows() {
        const hasDraft = this.hasDraftVersion;
        return this.versions.map((v) => {
            const isDraft = v.status === 'Draft';
            const isLive = v.status === 'Active';
            let detail;
            if (isDraft) {
                detail = 'Being edited here. Saved ' + this.formatWhen(v.lastModified) + (v.lastModifiedBy ? ' by ' + v.lastModifiedBy : '');
            } else {
                detail = (isLive ? 'Live since ' : 'Was live from ') + this.formatWhen(v.activatedOn || v.lastModified) + (v.lastModifiedBy ? ' · last changed by ' + v.lastModifiedBy : '');
            }
            return {
                id: v.id,
                title: 'Version ' + v.versionNumber,
                number: v.versionNumber,
                state: isDraft ? 'Draft' : isLive ? 'Live' : 'Earlier',
                stateCls: isDraft ? 'ver-state draft' : isLive ? 'ver-state live' : 'ver-state',
                detail,
                canMakeLive: !isDraft && !isLive,
                // With no draft, the live version is what the designer shows, so copying it would change nothing.
                canCopy: !isDraft && (!isLive || hasDraft)
            };
        });
    }

    async handleMakeLive(event) {
        const { id, number } = event.currentTarget.dataset;
        const ok = await LightningConfirm.open({
            label: `Put version ${number} live?`,
            message: `Documents generated from now on use version ${number}. The version that is live now is kept and can be put back the same way. Your draft is not changed.`,
            theme: 'warning'
        });
        if (!ok) {
            return;
        }
        await this.run(async () => {
            const keepDirty = this.dirty;
            if (keepDirty) {
                await this.save();
            }
            this.apply(await makeVersionLive({ templateId: this.templateId, versionId: id }));
            this.templates = await listTemplates();
            this.toast(`Version ${number} is live`, 'New documents use it straight away.' + (keepDirty ? ' Your unsaved changes were saved to the draft first.' : ''));
        });
    }

    async handleCopyToDraft(event) {
        const { id, number } = event.currentTarget.dataset;
        const replacing = this.hasDraftVersion || this.dirty;
        const ok = await LightningConfirm.open({
            label: `Edit a copy of version ${number}?`,
            message: replacing
                ? `The draft is replaced by a copy of version ${number}, including its translations. Changes in the current draft${this.dirty ? ', including unsaved ones,' : ''} are lost. The live version is not affected until you activate.`
                : `A new draft is started from version ${number}, including its translations. The live version is not affected until you activate.`,
            theme: replacing ? 'warning' : 'info'
        });
        if (!ok) {
            return;
        }
        await this.run(async () => {
            this.apply(await copyVersionToDraft({ templateId: this.templateId, versionId: id }));
            this.toast(`Draft now matches version ${number}`, 'Change it if needed, then Activate to put it live.');
        });
    }

    get isPanelTemplate() {
        return this.settingsPanel === 'template';
    }

    get isPanelPage() {
        return this.settingsPanel === 'page';
    }

    get isPanelHeaderFooter() {
        return this.settingsPanel === 'headerfooter';
    }

    get isPanelCalc() {
        return this.settingsPanel === 'calc';
    }

    get isPanelMessages() {
        return this.settingsPanel === 'messages';
    }

    get messages() {
        return this.body.messages || {};
    }

    handleMessage(event) {
        const key = event.target.dataset.key;
        const value = event.detail.value;
        this.mutate((body) => {
            body.messages = body.messages || {};
            if (value) {
                body.messages[key] = value;
            } else {
                delete body.messages[key];
            }
        });
    }

    handleMessageFocus(event) {
        this.focus = { prop: 'msg:' + event.target.dataset.key };
    }

    // ---------- Signature providers ----------

    providers = [];
    providerResults = {};

    async loadProviders() {
        try {
            this.providers = await listProviders();
        } catch (e) {
            this.providers = [];
        }
    }

    get providerRows() {
        return this.providers.map((p) => {
            const result = this.providerResults[p.name];
            return {
                ...p,
                state: p.active ? 'On' : 'Off',
                stateCls: p.active ? 'pill-on' : 'pill-off',
                result: result ? result.message : '',
                resultCls: result && result.ok ? 'test-ok' : 'test-bad'
            };
        });
    }

    async handleTestProvider(event) {
        const name = event.currentTarget.dataset.name;
        this.providerResults = { ...this.providerResults, [name]: { ok: true, message: 'Testing…' } };
        try {
            const result = await testProvider({ providerName: name });
            this.providerResults = { ...this.providerResults, [name]: result };
        } catch (e) {
            this.providerResults = { ...this.providerResults, [name]: { ok: false, message: this.messageOf(e) } };
        }
    }

    get isPanelConditions() {
        return this.settingsPanel === 'conditions';
    }

    // ---------- Conditions inside text ----------

    wrapMode = '';

    get wrapOptions() {
        return [
            { label: 'Always print it', value: '' },
            { label: 'Print it only when it has a value', value: 'filled' }
        ];
    }

    handleWrapMode(event) {
        this.wrapMode = event.detail.value;
    }

    get ifExample() {
        return '{{#if Field}} … {{else}} … {{/if}}';
    }

    get condExample() {
        return '{{#if cond:Name}}';
    }

    get endIfExample() {
        return '{{/if}}';
    }

    /** Shared, named conditions. Conditions made for a single part of a text are edited on that part instead. */
    get conditionRows() {
        return (this.body.conditions || [])
            .map((c, index) => ({
                ...c,
                index,
                usage: `{{#if cond:${c.name || 'Name'}}} … {{/if}}`
            }))
            .filter((c) => !c.auto);
    }

    get calcNameList() {
        return (this.body.calculations || []).filter((c) => c.name).map((c) => c.name);
    }

    get baseObjectName() {
        return this.tpl ? this.tpl.baseObject : null;
    }

    /** The object a direct related list holds, e.g. OpportunityLineItem for OpportunityLineItems. */
    childObjectOf(listName) {
        const info = this.tpl ? this.infoFor(this.tpl.baseObject) : null;
        const child = info && listName ? info.children.find((c) => c.name === listName) : null;
        return child ? child.childObject : null;
    }

    // ---------- Editing one conditional part, or one field, in a text ----------

    focusPart = null;

    handleSegClick(event) {
        const { kind, id } = event.currentTarget.dataset;
        if (kind !== 'section' && kind !== 'field') {
            return;
        }
        event.stopPropagation();
        const part = { blockId: id, kind };
        if (kind === 'section') {
            part.num = Number(event.currentTarget.dataset.num);
        } else {
            part.start = Number(event.currentTarget.dataset.start);
            part.end = Number(event.currentTarget.dataset.end);
            part.path = event.currentTarget.dataset.path;
        }
        if (this.selectedId !== id) {
            this.select(id);
        }
        this.panelTab = 'settings';
        this.focusPart = part;
    }

    handleLegendClick(event) {
        event.stopPropagation();
        const { id, num } = event.currentTarget.dataset;
        if (this.selectedId !== id) {
            this.select(id);
        }
        this.panelTab = 'settings';
        this.focusPart = { blockId: id, kind: 'section', num: Number(num) };
    }

    handlePartClose() {
        this.focusPart = null;
    }

    get selText() {
        const block = this.body.blocks.find((b) => b.id === this.selectedId);
        return block ? block.text || '' : '';
    }

    get partView() {
        const part = this.focusPart;
        if (!part || part.blockId !== this.selectedId || !this.selIsPlain) {
            return null;
        }
        const text = this.selText;
        if (part.kind === 'field') {
            if (text.substring(part.start, part.end).indexOf('{{') !== 0) {
                return null;
            }
            return { isField: true, label: this.fieldLabel(part.path) };
        }
        const section = this.findSection(text, part.num);
        if (!section) {
            return null;
        }
        let rule = null;
        let sharedName = '';
        if (section.target.startsWith('cond:')) {
            const condition = this.namedCondition(section.target.substring(5).trim());
            rule = condition ? condition.rule : null;
            sharedName = condition && !condition.auto ? condition.name : '';
        } else {
            rule = { conditions: [{ field: section.target, op: section.negate ? 'blank' : 'notBlank', value: '' }] };
        }
        return {
            isSection: true,
            num: part.num,
            title: 'Conditional part ' + part.num,
            ifText: section.ifText,
            elseText: section.elseText,
            rule,
            sharedName,
            sharedHint: sharedName ? `Uses the shared condition "${sharedName}". Changing it here changes every text that uses it.` : '',
            negated: section.negate && section.target.startsWith('cond:')
        };
    }

    /** Applies a change to the selected block's text, given the current text. */
    editSelText(change) {
        this.mutate((body) => {
            const block = this.blockIn(body);
            if (block) {
                block.text = change(block.text || '', body);
            }
        });
    }

    /**
     * Wraps a field in a condition, together with the comma or space after it and, when the field is alone
     * on its line, the line break, so nothing is left dangling when it is left out.
     */
    handleMakeConditional() {
        const part = this.focusPart;
        const text = this.selText;
        const token = text.substring(part.start, part.end);
        if (!token.startsWith('{{')) {
            return;
        }
        const after = text.substring(part.end);
        let trailing = new RegExp('^[ \\t]*[,;:|\\/\\u00b7\\u2013-]?[ \\t]*').exec(after)[0];
        const lineStart = text.lastIndexOf('\n', part.start - 1) + 1;
        const before = text.substring(lineStart, part.start);
        const rest = after.substring(trailing.length);
        if (!before.trim()) {
            if (rest.startsWith('\r\n')) {
                trailing += '\r\n';
            } else if (rest.startsWith('\n')) {
                trailing += '\n';
            }
        }
        const wrapped = `{{#if ${part.path}}}${token}${trailing}{{/if}}`;
        const num = (text.substring(0, part.start).match(/\{\{\s*#if\s/gi) || []).length + 1;
        this.editSelText((current) => current.substring(0, part.start) + wrapped + current.substring(part.end + trailing.length));
        this.focusPart = { blockId: part.blockId, kind: 'section', num };
    }

    handleRemoveField() {
        const part = this.focusPart;
        this.editSelText((current) => current.substring(0, part.start) + current.substring(part.end));
        this.focusPart = null;
    }

    handlePartText(event) {
        const value = event.detail.value || '';
        const num = this.focusPart.num;
        this.editSelText((current) => {
            const s = this.findSection(current, num);
            return s ? current.substring(0, s.openEnd) + value + current.substring(s.ifEnd) : current;
        });
    }

    handlePartElse(event) {
        const value = event.detail.value || '';
        const num = this.focusPart.num;
        this.editSelText((current) => {
            const s = this.findSection(current, num);
            if (!s) {
                return current;
            }
            const head = current.substring(0, s.ifEnd);
            const tail = current.substring(s.closeStart);
            return value ? head + '{{else}}' + value + tail : head + tail;
        });
    }

    /**
     * Saves the rule for a part. A single "has a value" or "is empty" check stays in the text itself
     * ({{#if City}}); anything more gets its own condition, kept with the template and named automatically.
     */
    handlePartRule(event) {
        const rule = event.detail.rule;
        const num = this.focusPart.num;
        this.editSelText((current, body) => {
            const s = this.findSection(current, num);
            if (!s) {
                return current;
            }
            body.conditions = body.conditions || [];
            const single = rule && rule.conditions.length === 1 && !(rule.logic || '').trim() ? rule.conditions[0] : null;
            const simple = single && single.field && !single.field.startsWith('calc:') && !single.field.endsWith('.') && (single.op === 'notBlank' || single.op === 'blank');
            const named = s.target.startsWith('cond:') ? body.conditions.find((c) => (c.name || '').toLowerCase() === s.target.substring(5).trim().toLowerCase()) : null;
            let tag;
            if (simple && (!named || named.auto)) {
                tag = `{{#if ${single.op === 'blank' ? 'not ' : ''}${single.field}}}`;
            } else if (named) {
                named.rule = rule;
                return current;
            } else {
                const taken = new Set(body.conditions.map((c) => (c.name || '').toLowerCase()));
                let n = 1;
                while (taken.has('part' + n)) {
                    n++;
                }
                const name = 'Part' + n;
                body.conditions.push({ name, rule, auto: true });
                tag = `{{#if cond:${name}}}`;
            }
            return current.substring(0, s.openStart) + tag + current.substring(s.openEnd);
        });
    }

    handlePartUnwrap() {
        const num = this.focusPart.num;
        this.editSelText((current) => {
            const s = this.findSection(current, num);
            return s ? current.substring(0, s.openStart) + s.ifText + current.substring(s.closeEnd) : current;
        });
        this.focusPart = null;
    }

    handlePartDelete() {
        const num = this.focusPart.num;
        this.editSelText((current) => {
            const s = this.findSection(current, num);
            return s ? current.substring(0, s.openStart) + current.substring(s.closeEnd) : current;
        });
        this.focusPart = null;
    }

    handleConditionRule(event) {
        const index = Number(event.target.dataset.index);
        const rule = event.detail.rule;
        this.mutate((body) => {
            if (body.conditions && body.conditions[index]) {
                body.conditions[index].rule = rule;
            }
        });
    }

    handleCalcFilter(event) {
        const index = Number(event.target.dataset.index);
        const rule = event.detail.rule;
        this.mutate((body) => {
            const calc = body.calculations[index];
            if (!calc) {
                return;
            }
            if (rule) {
                calc.filter = rule;
            } else {
                delete calc.filter;
            }
        });
    }

    /** Creates a calculated value over this table's list with the same row filter, and a summary row showing it. */
    handleMatchingTotal() {
        const block = this.body.blocks.find((b) => b.id === this.selectedId);
        if (!block || !block.source) {
            this.toast('Choose the list first', 'Pick where the rows come from, then add the total.', 'warning');
            return;
        }
        const columns = block.columns || [];
        const money = columns.filter((c) => c.align === 'right').map((c) => c.field);
        const field = money.length ? money[money.length - 1] : null;
        const taken = new Set((this.body.calculations || []).map((c) => c.name));
        let n = 1;
        while (taken.has('Total' + n)) {
            n++;
        }
        const name = 'Total' + n;
        this.mutate((body) => {
            const calc = { name, type: field ? 'sum' : 'count', source: block.source };
            if (field) {
                calc.field = field;
            }
            if (block.rowFilter) {
                calc.filter = JSON.parse(JSON.stringify(block.rowFilter));
            }
            body.calculations.push(calc);
            const target = this.blockIn(body);
            target.totals = target.totals || [];
            target.totals.push({ label: 'Total', calc: name });
        });
        this.toast('Total added', `${name} ${field ? 'adds up ' + field : 'counts the rows'} of this table's rows. Change it under Calculated values.`);
    }

    // ---------- Block layout ----------

    spanOptions = [
        { label: 'Full width', value: '100' },
        { label: 'Three quarters', value: '75' },
        { label: 'Two thirds', value: '67' },
        { label: 'Half', value: '50' },
        { label: 'One third', value: '33' },
        { label: 'One quarter', value: '25' }
    ];

    get selSpan() {
        return this.sel && this.sel.span ? String(this.sel.span) : '100';
    }

    /** The width choices, plus the current width when it was set by dragging a divider. */
    get selSpanOptions() {
        const current = this.selSpan;
        if (this.spanOptions.some((o) => o.value === current)) {
            return this.spanOptions;
        }
        return [{ label: current + '% (set by dragging)', value: current }, ...this.spanOptions];
    }

    get selCanLayout() {
        return !!this.sel && this.sel.type !== 'pagebreak';
    }

    get selIsFirst() {
        return !!this.sel && this.body.blocks.length > 0 && this.body.blocks[0].id === this.sel.id;
    }

    handleSpan(event) {
        const span = Number(event.detail.value);
        this.mutate((body) => {
            const block = this.blockIn(body);
            if (!block) {
                return;
            }
            if (span === 100) {
                delete block.span;
            } else {
                block.span = span;
            }
        });
    }

    /** Blocks grouped into rows the way the PDF lays them out: a block marked "beside" joins the row above. */
    get blockRows() {
        const rows = [];
        this.blockViews.forEach((view, index) => {
            const block = this.body.blocks[index];
            const beside = block.beside === true && block.type !== 'pagebreak' && rows.length > 0;
            if (!beside) {
                rows.push({ key: 'row-' + view.id, cells: [] });
            }
            rows[rows.length - 1].cells.push(view);
        });
        // A divider between neighbours in a row can be dragged to share the width differently.
        rows.forEach((row) => {
            row.cells = row.cells.map((cell, i) => ({
                ...cell,
                handleAfter: i < row.cells.length - 1,
                handleKey: 'h-' + cell.id,
                nextId: i < row.cells.length - 1 ? row.cells[i + 1].id : null
            }));
        });
        return rows;
    }

    // ---------- Arranging blocks by dragging ----------

    dragId;
    drop;
    liveSpans = {};
    resizing;

    /** Groups block indexes into rows: [[0], [1, 2], [3]]. */
    rowsOf(blocks) {
        const rows = [];
        blocks.forEach((b, i) => {
            if (b.beside === true && b.type !== 'pagebreak' && rows.length) {
                rows[rows.length - 1].push(i);
            } else {
                rows.push([i]);
            }
        });
        return rows;
    }

    /** A block's width as shown: its own width, or an equal share of its row when it has none. */
    effectiveSpan(blocks, id) {
        const row = this.rowsOf(blocks).find((r) => r.some((i) => blocks[i].id === id));
        const block = blocks.find((b) => b.id === id);
        if (!row || !block) {
            return 100;
        }
        if (block.span) {
            return Number(block.span);
        }
        return row.length > 1 ? Math.floor(100 / row.length) : 100;
    }

    handleDragStart(event) {
        this.dragId = event.currentTarget.dataset.id;
        try {
            event.dataTransfer.setData('text/plain', this.dragId);
            event.dataTransfer.effectAllowed = 'move';
        } catch (e) {
            // Some browsers limit dataTransfer; the block id is kept on the component anyway.
        }
    }

    handleDragOver(event) {
        if (!this.dragId) {
            return;
        }
        event.preventDefault();
        const id = event.currentTarget.dataset.id;
        if (id === this.dragId) {
            if (this.drop) {
                this.drop = undefined;
            }
            return;
        }
        const box = event.currentTarget.getBoundingClientRect();
        const x = (event.clientX - box.left) / Math.max(box.width, 1);
        const y = (event.clientY - box.top) / Math.max(box.height, 1);
        let zone;
        if (x < 0.25) {
            zone = 'left';
        } else if (x > 0.75) {
            zone = 'right';
        } else {
            zone = y < 0.5 ? 'above' : 'below';
        }
        if (!this.drop || this.drop.id !== id || this.drop.zone !== zone) {
            this.drop = { id, zone };
        }
    }

    handleDrop(event) {
        event.preventDefault();
        event.stopPropagation();
        const dragId = this.dragId;
        const drop = this.drop;
        this.dragId = undefined;
        this.drop = undefined;
        if (!dragId || !drop) {
            return;
        }
        const result = this.placeBlock(this.body.blocks, dragId, drop.id, drop.zone);
        if (result.error) {
            this.toast('Cannot place it there', result.error, 'warning');
            return;
        }
        this.mutate((body) => {
            body.blocks = result.blocks;
        });
    }

    handleDragEnd() {
        this.dragId = undefined;
        this.drop = undefined;
    }

    /**
     * Moves a block next to another: to its left or right in the same row, or above or below that row.
     * Rows that change get equal widths; a block that ends up alone goes back to full width.
     */
    placeBlock(blocks, dragId, targetId, zone) {
        const list = blocks.map((b) => ({ ...b }));
        const from = list.findIndex((b) => b.id === dragId);
        if (from < 0 || dragId === targetId) {
            return { blocks };
        }
        const touched = new Set([dragId]);
        const oldRow = this.rowsOf(list).find((r) => r.includes(from));
        oldRow.forEach((i) => touched.add(list[i].id));

        const dragged = list[from];
        const next = list[from + 1];
        if (dragged.beside !== true && next && next.beside === true) {
            next.beside = false;
        }
        list.splice(from, 1);
        delete dragged.beside;

        const t = list.findIndex((b) => b.id === targetId);
        let where = zone;
        if ((dragged.type === 'pagebreak' || list[t].type === 'pagebreak') && (where === 'left' || where === 'right')) {
            where = where === 'left' ? 'above' : 'below';
        }
        const row = this.rowsOf(list).find((r) => r.includes(t));
        row.forEach((i) => touched.add(list[i].id));
        if (where === 'left' || where === 'right') {
            if (row.length >= MAX_ROW) {
                return { error: `A row holds up to ${MAX_ROW} blocks. Drop it above or below the row instead.` };
            }
            if (where === 'left') {
                if (list[t].beside === true) {
                    dragged.beside = true;
                }
                list[t].beside = true;
                list.splice(t, 0, dragged);
            } else {
                dragged.beside = true;
                list.splice(t + 1, 0, dragged);
            }
        } else if (where === 'above') {
            list.splice(row[0], 0, dragged);
        } else {
            list.splice(row[row.length - 1] + 1, 0, dragged);
        }

        this.rowsOf(list).forEach((r) => {
            if (!r.some((i) => touched.has(list[i].id))) {
                return;
            }
            if (r.length === 1) {
                delete list[r[0]].span;
                return;
            }
            const share = Math.floor(100 / r.length);
            r.forEach((i, k) => {
                list[i].span = k === r.length - 1 ? 100 - share * (r.length - 1) : share;
            });
        });
        list.forEach((b) => {
            if (b.beside !== true) {
                delete b.beside;
            }
        });
        return { blocks: list };
    }

    /** Snaps a dragged width to steps of 5%, and to thirds when close. */
    snapSpan(value) {
        if (Math.abs(value - 100 / 3) < 2.5) {
            return 33;
        }
        if (Math.abs(value - 200 / 3) < 2.5) {
            return 67;
        }
        return Math.round(value / 5) * 5;
    }

    handleResizeStart(event) {
        event.preventDefault();
        event.stopPropagation();
        const { left, right } = event.currentTarget.dataset;
        const rowEl = event.currentTarget.parentElement;
        const width = rowEl ? rowEl.getBoundingClientRect().width : 0;
        if (!width) {
            return;
        }
        this.resizing = {
            left,
            right,
            startX: event.clientX,
            width,
            leftSpan: this.effectiveSpan(this.body.blocks, left),
            rightSpan: this.effectiveSpan(this.body.blocks, right)
        };
        try {
            event.currentTarget.setPointerCapture(event.pointerId);
        } catch (e) {
            // Without capture the drag still works while the pointer stays over the divider's row.
        }
    }

    handleResizeMove(event) {
        const r = this.resizing;
        if (!r) {
            return;
        }
        const total = r.leftSpan + r.rightSpan;
        const delta = ((event.clientX - r.startX) / r.width) * 100;
        const leftSpan = Math.max(MIN_SPAN, Math.min(total - MIN_SPAN, this.snapSpan(r.leftSpan + delta)));
        if (this.liveSpans[r.left] !== leftSpan) {
            this.liveSpans = { [r.left]: leftSpan, [r.right]: total - leftSpan };
        }
    }

    handleResizeEnd() {
        const r = this.resizing;
        const spans = this.liveSpans;
        this.resizing = undefined;
        this.liveSpans = {};
        if (!r || spans[r.left] === undefined) {
            return;
        }
        this.mutate((body) => {
            body.blocks.forEach((b) => {
                if (spans[b.id] !== undefined) {
                    b.span = spans[b.id];
                }
            });
        });
    }

    /** Keyboard: arrow keys on a focused divider move it by 5%. */
    handleResizeKey(event) {
        if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') {
            return;
        }
        event.preventDefault();
        const { left, right } = event.currentTarget.dataset;
        const leftSpan = this.effectiveSpan(this.body.blocks, left);
        const rightSpan = this.effectiveSpan(this.body.blocks, right);
        const step = event.key === 'ArrowLeft' ? -5 : 5;
        const nextLeft = Math.max(MIN_SPAN, Math.min(leftSpan + rightSpan - MIN_SPAN, leftSpan + step));
        this.mutate((body) => {
            body.blocks.forEach((b) => {
                if (b.id === left) {
                    b.span = nextLeft;
                } else if (b.id === right) {
                    b.span = leftSpan + rightSpan - nextLeft;
                }
            });
        });
    }

    get isPanelSigners() {
        return this.settingsPanel === 'signers';
    }

    // ---------- Signers and signature blocks ----------

    get signerRows() {
        return (this.body.signers || []).map((s, index) => {
            const mode = this.signerMode(s);
            return { ...s, index, num: index + 1, mode, isTyped: mode === 'typed', isPerson: mode === 'person', isList: mode === 'list', ruleObject: this.childObjectOf(s.source) };
        });
    }

    signerMode(signer) {
        if (signer.source) {
            return 'list';
        }
        return signer.mode === 'person' || signer.person ? 'person' : signer.mode === 'list' ? 'list' : 'typed';
    }

    signerModeOptions = [
        { label: 'A person on this record', value: 'person' },
        { label: 'Everyone in a related list', value: 'list' },
        { label: 'Typed in or from fields', value: 'typed' }
    ];

    /** Lookups on this object to people who can sign: users, contacts and leads. */
    get personOptions() {
        const info = this.tpl ? this.infoFor(this.tpl.baseObject) : null;
        if (!info) {
            return [];
        }
        const options = [];
        if (['Contact', 'Lead', 'User'].includes(info.name)) {
            options.push({ label: `This ${info.label.toLowerCase()} itself`, value: '__self' });
        }
        info.fields
            .filter((f) => f.relationshipName && ['User', 'Contact', 'Lead'].includes(f.referenceTo))
            .map((f) => ({ label: `${f.label.replace(/ ID$/, '')} (${f.referenceTo})`, value: f.relationshipName }))
            .sort((a, b) => a.label.localeCompare(b.label))
            .forEach((o) => options.push(o));
        return options;
    }

    get signerListOptions() {
        const info = this.tpl ? this.infoFor(this.tpl.baseObject) : null;
        if (!info) {
            return [];
        }
        return info.children
            .filter((c) => !NOISE_LISTS.test(c.name))
            .map((c) => ({ label: `${c.label || c.name} (${c.name})`, value: c.name }))
            .sort((a, b) => a.label.localeCompare(b.label));
    }

    updateSigner(index, change) {
        this.mutate((body) => {
            const signer = body.signers && body.signers[index];
            if (signer) {
                change(signer);
            }
        });
    }

    handleSignerMode(event) {
        const index = Number(event.target.dataset.index);
        const mode = event.detail.value;
        this.updateSigner(index, (signer) => {
            signer.mode = mode;
            if (mode !== 'list') {
                delete signer.source;
                delete signer.nameField;
                delete signer.emailField;
                delete signer.filter;
            }
            if (mode !== 'person') {
                delete signer.person;
            }
            if (mode !== 'typed') {
                signer.name = '';
                signer.email = '';
            }
        });
    }

    handleSignerPerson(event) {
        const index = Number(event.target.dataset.index);
        const rel = event.detail.value;
        const prefix = rel === '__self' ? '' : rel + '.';
        this.updateSigner(index, (signer) => {
            signer.person = rel;
            signer.name = `{{${prefix}Name}}`;
            signer.email = `{{${prefix}Email}}`;
        });
    }

    /** Picks sensible name and email fields for the chosen list, e.g. Contact.Name for contact roles. */
    async handleSignerList(event) {
        const index = Number(event.target.dataset.index);
        const source = event.detail.value;
        const owner = this.infoFor(this.tpl.baseObject);
        const child = owner && owner.children.find((c) => c.name === source);
        let nameField = 'Name';
        let emailField = 'Email';
        if (child) {
            try {
                const info = await this.ensureObject(child.childObject);
                const hasEmail = info.fields.some((f) => f.name === 'Email');
                const person = info.fields.find((f) => f.relationshipName && ['Contact', 'User', 'Lead'].includes(f.referenceTo) && /contact|user|lead/i.test(f.relationshipName));
                if (!hasEmail && person) {
                    nameField = person.relationshipName + '.Name';
                    emailField = person.relationshipName + '.Email';
                }
            } catch (e) {
                nameField = 'Name';
            }
        }
        this.updateSigner(index, (signer) => {
            signer.source = source;
            signer.nameField = nameField;
            signer.emailField = emailField;
            signer.name = '';
            signer.email = '';
        });
    }

    handleSignerFilter(event) {
        const index = Number(event.target.dataset.index);
        const rule = event.detail.rule;
        this.updateSigner(index, (signer) => {
            if (rule) {
                signer.filter = rule;
            } else {
                delete signer.filter;
            }
        });
    }

    get noSigners() {
        return !(this.body.signers || []).length;
    }

    /** How a signature block is drawn on the page: one signing area per signer. */
    get signatureAreas() {
        // Empty rows are ignored when documents are generated, so they are not drawn either.
        const signers = (this.body.signers || []).filter((s) => s.source || s.role || s.name || s.email);
        if (!signers.length) {
            return [{ key: 0, role: 'Signature', segs: [] }];
        }
        return signers.map((s, index) => ({
            key: index,
            role: (s.role || `Signer ${index + 1}`) + (s.source ? ` · one area per person in ${s.source}` : ''),
            segs: s.source ? [] : this.segments(s.name)
        }));
    }

    get selIsSignature() {
        return !!this.sel && this.sel.type === 'signature';
    }

    get selShowDate() {
        return !!this.sel && this.sel.showDate !== false;
    }

    handleSignerFocus(event) {
        this.focus = { prop: 'signer:' + event.target.dataset.prop, index: event.target.dataset.index };
    }

    openSigners() {
        this.handleDeselect();
        this.settingsPanel = 'signers';
        this.panelTab = 'settings';
    }

    get panelTitle() {
        const titles = { template: 'Name and languages', page: 'Page setup', headerfooter: 'Header, footer, watermark', calc: 'Calculated values', signers: 'Signers', conditions: 'Conditions', messages: 'Email and signing wording', versions: 'Versions' };
        return titles[this.settingsPanel] || 'Template';
    }

    // ---------- Canvas ----------

    get blockViews() {
        const count = this.body.blocks.length;
        return this.body.blocks.map((b, index) => {
            const type = b.type || 'text';
            const rule = this.ruleSummary(b.showIf);
            const textual = type === 'heading' || (type === 'text' && !b.rich);
            const view = textual ? this.textView(b.text, b.id) : { segs: [], legend: [] };
            const live = this.liveSpans[b.id];
            const span = live !== undefined ? live : b.span && Number(b.span) !== 100 ? Number(b.span) : null;
            let cls = 'block' + (b.id === this.selectedId ? ' selected' : '');
            if (this.dragId === b.id) {
                cls += ' dragging';
            }
            if (this.drop && this.drop.id === b.id) {
                cls += ' drop-' + this.drop.zone;
            }
            return {
                id: b.id,
                cls,
                livePct: live !== undefined ? live + '%' : '',
                textSegs: view.segs,
                legend: view.legend,
                hasLegend: view.legend.length > 0,
                label: TYPE_LABELS[type] || type,
                isHeading: type === 'heading',
                isText: type === 'text' && !b.rich,
                isRich: type === 'text' && !!b.rich,
                richCls: 'content rich' + (b.align ? ' align-' + b.align : ''),
                richHtml: b.text || '',
                isImage: type === 'image',
                hasImage: type === 'image' && !!b.contentVersionId,
                noImage: type === 'image' && !b.contentVersionId,
                imgUrl: b.contentVersionId ? FILE_URL + b.contentVersionId : '',
                imgStyle: `width:${Number(b.width) || 200}px;max-width:100%`,
                imgCls: 'image-wrap' + (b.align ? ' align-' + b.align : ''),
                isSignature: type === 'signature',
                sigShowDate: b.showDate !== false,
                sigShowName: b.showName === true,
                isTable: type === 'table',
                isTerms: type === 'terms',
                isBreak: type === 'pagebreak',
                textCls: 'content' + (b.align ? ' align-' + b.align : '') + (type === 'heading' ? ' heading-' + (b.level || 1) : ''),
                segs: this.segments(b.text),
                empty: (type === 'heading' || type === 'text') && !b.text,
                rule,
                hasRule: !!rule,
                elseSegs: this.segments(b.elseText),
                hasElse: !!b.elseText,
                source: b.source || 'no list chosen yet',
                columns: (b.columns || []).map((c, i) => ({
                    key: i,
                    header: c.header || c.field,
                    field: c.field,
                    cls: c.align ? 'cell align-' + c.align : 'cell',
                    conditional: c.show === 'filled' || c.show === 'rule',
                    showTitle: c.show === 'filled' ? 'Printed only when some row has a value' : c.show === 'rule' ? 'Printed only when its rule is met' : ''
                })),
                noColumns: !(b.columns || []).length,
                rowRule: this.ruleSummary(b.rowFilter).replace('Show only if', 'Only rows where'),
                totals: (b.totals || []).map((t, i) => ({ key: i, label: t.label, calc: t.calc })),
                title: b.title,
                items: (b.items || []).map((item, i) => {
                    const itemRule = this.ruleSummary(item.showIf);
                    return { key: item.id || i, num: i + 1 + '.', segs: this.segments(item.text), rule: itemRule, hasRule: !!itemRule };
                }),
                clauseCategory: b.clauseCategory,
                cellStyle: span ? `flex: 0 1 ${span}%; min-width: 0` : 'flex: 1 1 100%; min-width: 0',
                first: index === 0,
                last: index === count - 1
            };
        });
    }

    get noBlocks() {
        return this.body.blocks.length === 0;
    }

    handleSelect(event) {
        this.select(event.currentTarget.dataset.id);
    }

    handleBlockKey(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.select(event.currentTarget.dataset.id);
        }
    }

    async select(id) {
        if (this.selectedId !== id) {
            this.focusPart = null;
        }
        this.selectedId = id;
        this.pickerPath = [];
        this.search = '';
        this.focus = { prop: 'text' };
        const block = this.body.blocks.find((b) => b.id === id);
        this.tableObject = undefined;
        if (block && block.type === 'table' && block.source) {
            try {
                this.tableObject = await this.resolveListObject(block.source);
            } catch (e) {
                this.tableObject = undefined;
            }
        }
        // A table with a list chosen but no columns yet needs the field list next; everything else opens its settings.
        const needsColumns = block && block.type === 'table' && block.source && !(block.columns || []).length;
        this.panelTab = needsColumns ? 'fields' : 'settings';
    }

    handleDeselect() {
        this.focusPart = null;
        this.selectedId = undefined;
        this.pickerPath = [];
        this.tableObject = undefined;
    }

    handleAddBlock(event) {
        const type = event.currentTarget.dataset.type;
        this.addBlock(type, {});
    }

    addBlock(type, extra) {
        const block = { id: this.uid(), type, ...extra };
        if (type === 'heading') {
            block.text = block.text || 'Heading';
            block.level = 1;
        } else if (type === 'text') {
            block.text = block.text || '';
        } else if (type === 'table') {
            block.columns = block.columns || [];
            block.hideWhenEmpty = true;
        } else if (type === 'terms') {
            block.title = 'Terms';
            block.items = [{ id: this.uid(), text: '' }];
        } else if (type === 'image') {
            block.width = 200;
        } else if (type === 'signature') {
            block.showDate = true;
        }
        const after = this.selectedId;
        this.mutate((body) => {
            const at = body.blocks.findIndex((b) => b.id === after);
            body.blocks.splice(at < 0 ? body.blocks.length : at + 1, 0, block);
        });
        this.select(block.id);
    }

    handleMove(event) {
        event.stopPropagation();
        const id = event.target.dataset.id;
        const delta = Number(event.target.dataset.delta);
        this.mutate((body) => {
            const from = body.blocks.findIndex((b) => b.id === id);
            const to = from + delta;
            if (from < 0 || to < 0 || to >= body.blocks.length) {
                return;
            }
            const [moved] = body.blocks.splice(from, 1);
            body.blocks.splice(to, 0, moved);
        });
    }

    handleDelete(event) {
        event.stopPropagation();
        const id = event.target.dataset.id;
        this.mutate((body) => {
            body.blocks = body.blocks.filter((b) => b.id !== id);
        });
        if (this.selectedId === id) {
            this.handleDeselect();
        }
    }

    // ---------- Inspector ----------

    get sel() {
        const block = this.body.blocks.find((b) => b.id === this.selectedId);
        if (!block) {
            return null;
        }
        return {
            ...block,
            level: String(block.level || 1),
            align: block.align || '',
            orderDirection: block.orderDirection || 'ASC',
            columns: (block.columns || []).map((c, index) => ({
                ...c,
                index,
                align: c.align || '',
                format: c.format || '',
                show: c.show || 'always',
                showRule: c.show === 'rule'
            })),
            totals: (block.totals || []).map((t, index) => ({ ...t, index })),
            items: (block.items || []).map((item, index) => ({ ...item, index, num: index + 1 }))
        };
    }

    get selLabel() {
        return this.sel ? TYPE_LABELS[this.sel.type] || 'Block' : '';
    }

    get selIsHeading() {
        return !!this.sel && this.sel.type === 'heading';
    }

    get selIsTextual() {
        return !!this.sel && (this.sel.type === 'heading' || this.sel.type === 'text');
    }

    get selIsTable() {
        return !!this.sel && this.sel.type === 'table';
    }

    get selIsText() {
        return !!this.sel && this.sel.type === 'text';
    }

    get selIsRich() {
        return this.selIsText && !!this.sel.rich;
    }

    get selIsPlain() {
        return this.selIsTextual && !this.selIsRich;
    }

    get selIsImage() {
        return !!this.sel && this.sel.type === 'image';
    }

    get selImageUrl() {
        return this.sel && this.sel.contentVersionId ? FILE_URL + this.sel.contentVersionId : '';
    }

    /** Switches a text block between plain and rich text, converting what is already typed. */
    handleRichToggle(event) {
        const rich = event.target.checked;
        this.mutate((body) => {
            const block = this.blockIn(body);
            if (!block) {
                return;
            }
            const text = block.text || '';
            if (rich) {
                const escaped = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
                block.text = escaped
                    .split(/\r?\n/)
                    .map((line) => `<p>${line || '<br>'}</p>`)
                    .join('');
                block.rich = true;
            } else {
                block.text = text
                    .replace(/<\/p>\s*<p[^>]*>/gi, '\n')
                    .replace(/<br\s*\/?>/gi, '\n')
                    .replace(/<[^>]+>/g, '')
                    .replace(/&lt;/g, '<')
                    .replace(/&gt;/g, '>')
                    .replace(/&amp;/g, '&')
                    .replace(/&nbsp;/g, ' ');
                delete block.rich;
            }
        });
    }

    handleRichChange(event) {
        const value = event.target.value;
        this.focus = { prop: 'text' };
        this.mutate((body) => {
            const block = this.blockIn(body);
            if (block) {
                block.text = value;
            }
        });
    }

    handleImageUpload(event) {
        const file = event.detail.files && event.detail.files[0];
        if (!file) {
            return;
        }
        this.mutate((body) => {
            const block = this.blockIn(body);
            if (block) {
                block.contentVersionId = file.contentVersionId;
            }
        });
    }

    // ---------- Page setup, header, footer, watermark ----------

    get page() {
        const page = this.body.page || {};
        return { size: page.size || 'A4', orientation: page.orientation || 'portrait', margin: page.margin || 'normal' };
    }

    get header() {
        return (this.body.page && this.body.page.header) || {};
    }

    get footer() {
        return (this.body.page && this.body.page.footer) || {};
    }

    get watermark() {
        return (this.body.page && this.body.page.watermark) || {};
    }

    get logoUrl() {
        return this.header.logoId ? FILE_URL + this.header.logoId : '';
    }

    get logoStyle() {
        return `width:${Number(this.header.logoWidth) || 120}px;max-width:100%`;
    }

    get hasHeader() {
        return !!(this.header.text || this.header.logoId);
    }

    get hasFooter() {
        return !!(this.footer.text || this.footer.pageNumbers);
    }

    get headerSegs() {
        return this.segments(this.header.text);
    }

    get footerSegs() {
        return this.segments(this.footer.text);
    }

    get watermarkLabel() {
        if (!this.watermark.text) {
            return '';
        }
        const rule = this.ruleSummary(this.watermark.showIf);
        return `Watermark "${this.watermark.text}" ` + (rule ? rule.replace('Show only if', 'only if') : 'on every document');
    }

    /** Sizes the on-screen page to the chosen paper so the design matches the PDF's proportions. */
    get pageStyle() {
        const page = this.page;
        const ratio = PAGE_SHAPES[page.size.toLowerCase()] || PAGE_SHAPES.a4;
        const landscape = page.orientation === 'landscape';
        const width = landscape ? 62 : 48;
        const height = landscape ? width / ratio : width * ratio;
        return `max-width:${width}rem;min-height:${height.toFixed(1)}rem;padding:${PAGE_PADDING[page.margin] || PAGE_PADDING.normal}`;
    }

    get pageLabel() {
        const size = this.pageSizeOptions.find((o) => o.value === this.page.size);
        return `${size ? size.label : this.page.size} · ${this.page.orientation} · ${this.page.margin} margins`;
    }

    handlePage(event) {
        const { section, prop } = event.target.dataset;
        const value = this.valueOf(event);
        this.mutate((body) => {
            body.page = body.page || {};
            let target = body.page;
            if (section) {
                body.page[section] = body.page[section] || {};
                target = body.page[section];
            }
            if (value === '' || value === null || value === undefined || value === false) {
                delete target[prop];
            } else {
                target[prop] = value;
            }
        });
    }

    handleWatermarkRule(event) {
        const rule = event.detail.rule;
        this.mutate((body) => {
            body.page = body.page || {};
            body.page.watermark = body.page.watermark || {};
            if (rule) {
                body.page.watermark.showIf = rule;
            } else {
                delete body.page.watermark.showIf;
            }
        });
    }

    handleLogoUpload(event) {
        const file = event.detail.files && event.detail.files[0];
        if (!file) {
            return;
        }
        this.mutate((body) => {
            body.page = body.page || {};
            body.page.header = body.page.header || {};
            body.page.header.logoId = file.contentVersionId;
        });
    }

    handleRemoveLogo() {
        this.mutate((body) => {
            if (body.page && body.page.header) {
                delete body.page.header.logoId;
            }
        });
    }

    get richFormats() {
        return ['font', 'size', 'bold', 'italic', 'underline', 'strike', 'list', 'indent', 'align', 'color', 'background', 'clean'];
    }

    handlePageFocus(event) {
        this.focus = { prop: event.target.dataset.focus };
    }

    handleShowAllLists(event) {
        this.showAllLists = event.target.checked;
    }

    get selIsTerms() {
        return !!this.sel && this.sel.type === 'terms';
    }

    get selHasRule() {
        return !!this.sel && this.sel.type !== 'pagebreak';
    }

    handleProp(event) {
        const prop = event.target.dataset.prop;
        let value = this.valueOf(event);
        if (prop === 'level') {
            value = Number(value);
        }
        this.mutate((body) => {
            const block = this.blockIn(body);
            if (!block) {
                return;
            }
            if (value === '' || value === null || value === undefined) {
                delete block[prop];
            } else {
                block[prop] = value;
            }
        });
        if (prop === 'source') {
            this.select(this.selectedId);
        }
    }

    handleFocus(event) {
        this.focus = { prop: event.target.dataset.prop, index: event.target.dataset.index };
    }

    handleRule(event) {
        const target = event.target.dataset.target;
        const index = Number(event.target.dataset.index);
        const rule = event.detail.rule;
        this.mutate((body) => {
            const block = this.blockIn(body);
            if (!block) {
                return;
            }
            let holder = block;
            if (target === 'item') {
                holder = block.items[index];
            } else if (target === 'column') {
                holder = (block.columns || [])[index];
            }
            if (!holder) {
                return;
            }
            const key = target === 'rowFilter' ? 'rowFilter' : 'showIf';
            if (rule) {
                holder[key] = rule;
            } else {
                delete holder[key];
            }
        });
    }

    listOf(body, listName) {
        if (listName === 'conditions') {
            body.conditions = body.conditions || [];
            return body.conditions;
        }
        if (listName === 'signers') {
            body.signers = body.signers || [];
            return body.signers;
        }
        if (listName === 'calculations') {
            return body.calculations;
        }
        const block = this.blockIn(body);
        if (!block) {
            return null;
        }
        block[listName] = block[listName] || [];
        return block[listName];
    }

    handleRow(event) {
        const { list, prop } = event.target.dataset;
        const index = Number(event.target.dataset.index);
        const value = this.valueOf(event);
        this.mutate((body) => {
            const rows = this.listOf(body, list);
            if (!rows || !rows[index]) {
                return;
            }
            if (value === '' || value === null || value === undefined || (prop === 'show' && value === 'always')) {
                delete rows[index][prop];
            } else {
                rows[index][prop] = value;
            }
            // A column's rule only applies while "Only when a rule is met" is chosen.
            if (prop === 'show' && value !== 'rule') {
                delete rows[index].showIf;
            }
        });
    }

    get columnShowOptions() {
        return [
            { label: 'Always', value: 'always' },
            { label: 'Only when some row has a value', value: 'filled' },
            { label: 'Only when a rule is met', value: 'rule' }
        ];
    }

    handleItemText(event) {
        const index = Number(event.target.dataset.index);
        const value = event.detail.value;
        this.mutate((body) => {
            const block = this.blockIn(body);
            if (block && block.items && block.items[index]) {
                block.items[index].text = value;
            }
        });
    }

    get fileNameHint() {
        return 'e.g. Quote - {{Account.Name}}';
    }

    get noTransRows() {
        return this.transParts.length === 0;
    }

    handleAddRow(event) {
        const list = event.target.dataset.list;
        const defaults = {
            columns: { header: '', field: '' },
            totals: { label: 'Total', calc: '' },
            items: { id: this.uid(), text: '' },
            calculations: { name: '', type: 'count', source: '' },
            signers: { role: 'Signer ' + ((this.body.signers || []).length + 1), mode: 'person', name: '', email: '' },
            conditions: { name: 'Condition' + ((this.body.conditions || []).length + 1), rule: null }
        };
        this.mutate((body) => {
            const rows = this.listOf(body, list);
            if (rows) {
                rows.push({ ...defaults[list] });
            }
        });
    }

    handleRemoveRow(event) {
        const list = event.target.dataset.list;
        const index = Number(event.target.dataset.index);
        this.mutate((body) => {
            const rows = this.listOf(body, list);
            if (rows) {
                rows.splice(index, 1);
            }
        });
    }

    get calcRows() {
        const base = this.tpl ? this.infoFor(this.tpl.baseObject) : null;
        const lists = base
            ? base.children.filter((ch) => !NOISE_LISTS.test(ch.name)).map((ch) => ({ label: `${ch.label || ch.name} (${ch.name})`, value: ch.name })).sort((a, b) => a.label.localeCompare(b.label))
            : [];
        return this.body.calculations.map((c, index) => {
            const isFormula = c.type === 'formula';
            const childObject = isFormula ? null : this.childObjectOf(c.source);
            const childInfo = childObject ? this.infoFor(childObject) : null;
            if (childObject && !childInfo) {
                this.loadLater(childObject);
            }
            const listOptions = [...lists];
            if (c.source && !listOptions.some((o) => o.value === c.source)) {
                listOptions.unshift({ label: c.source, value: c.source });
            }
            const numericOptions = childInfo
                ? childInfo.fields.filter((f) => NUMERIC_TYPES.includes(f.type)).map((f) => ({ label: f.label, value: f.name })).sort((a, b) => a.label.localeCompare(b.label))
                : [];
            if (c.field && numericOptions.length && !numericOptions.some((o) => o.value === c.field)) {
                numericOptions.unshift({ label: c.field, value: c.field });
            }
            const fx = isFormula ? this.formulaView(c.expression || '', index) : {};
            const result = this.calcPreview && this.calcPreview.values ? this.calcPreview.values[c.name] : undefined;
            return {
                ...c,
                index,
                type: c.type || 'count',
                format: c.format || '',
                isFormula,
                isRollup: !isFormula,
                needsField: !isFormula && c.type !== 'count' && !!c.type,
                listOptions,
                childObject,
                fieldPicker: numericOptions.length > 0,
                numericOptions,
                fxSegs: fx.segs || [],
                fxProblem: fx.problem || '',
                fxInputId: 'fx-' + index,
                suggestions: this.fx && this.fx.index === index ? this.fx.items : [],
                showSuggest: !!(this.fx && this.fx.index === index && this.fx.items.length),
                hasResult: result !== undefined,
                result: result !== undefined ? '= ' + result : ''
            };
        });
    }

    pendingObjects = new Set();

    /** Describes an object in the background; the panel redraws when it arrives. */
    loadLater(objectName) {
        const key = (objectName || '').toLowerCase();
        if (!key || this.pendingObjects.has(key) || this.objects[key]) {
            return;
        }
        this.pendingObjects.add(key);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        Promise.resolve()
            .then(() => this.ensureObject(objectName))
            .catch(() => undefined)
            .finally(() => this.pendingObjects.delete(key));
    }

    /** Finds the field a path names, walking through related records. */
    resolvePath(path) {
        let info = this.tpl ? this.infoFor(this.tpl.baseObject) : null;
        const parts = path.split('.');
        const labels = [];
        for (let i = 0; i < parts.length; i++) {
            if (!info) {
                return { pending: true };
            }
            const name = parts[i].toLowerCase();
            if (i < parts.length - 1) {
                const lookup = info.fields.find((f) => (f.relationshipName || '').toLowerCase() === name);
                if (!lookup) {
                    return { missing: true, where: info.label };
                }
                labels.push(lookup.label.replace(/ ID$/, ''));
                info = this.infoFor(lookup.referenceTo);
                if (!info) {
                    this.loadLater(lookup.referenceTo);
                }
            } else {
                const field = info.fields.find((f) => f.name.toLowerCase() === name);
                if (!field) {
                    return { missing: true, where: info.label };
                }
                labels.push(field.label);
                return { field, label: labels.join(' › ') };
            }
        }
        return { pending: true };
    }

    /** The formula read back with field labels as chips, and the first problem found, if any. */
    formulaView(expression, index) {
        const segs = [];
        let problem = '';
        const note = (text) => {
            problem = problem || text;
        };
        const earlier = new Set(this.body.calculations.slice(0, index).map((c) => c.name));
        const all = new Set(this.body.calculations.map((c) => c.name));
        const tokens = expression.match(FX_TOKEN) || [];
        let depth = 0;
        let n = 0;
        tokens.forEach((token, i) => {
            if (/^\s+$/.test(token)) {
                return;
            }
            let nextIndex = i + 1;
            while (nextIndex < tokens.length && /^\s+$/.test(tokens[nextIndex])) {
                nextIndex++;
            }
            const next = tokens[nextIndex];
            let cls = 'fx-op';
            let text = FX_SHOW[token] || token;
            let title = '';
            if (/^\d/.test(token)) {
                cls = 'fx-num';
            } else if (token.startsWith('calc:')) {
                const name = token.substring(5);
                text = name;
                cls = 'chip chip-calc';
                if (!all.has(name)) {
                    cls += ' fx-bad';
                    note(`There is no calculated value named ${name}.`);
                } else if (!earlier.has(name)) {
                    cls += ' fx-bad';
                    note(`${name} is worked out after this formula. Move this formula below ${name}.`);
                }
            } else if (/^[A-Za-z_]/.test(token)) {
                if (next === '(') {
                    const fn = FX_FUNCTIONS.find((f) => f.name === token.toUpperCase());
                    cls = fn ? 'fx-fn' : 'fx-fn fx-bad';
                    title = fn ? fn.hint : '';
                    if (!fn) {
                        note(`${token} is not a function. Use ${FX_FUNCTIONS.map((f) => f.name).join(', ')}.`);
                    }
                } else {
                    const found = this.resolvePath(token);
                    cls = 'chip';
                    title = token;
                    if (found.field) {
                        text = found.label;
                        if (!NUMERIC_TYPES.includes(found.field.type)) {
                            cls += ' fx-warn';
                            note(`${found.label} is not a number field, so it can only be used if it holds a number.`);
                        }
                    } else if (found.missing) {
                        cls += ' fx-bad';
                        note(`${token} is not a field on ${found.where}.`);
                    }
                }
            } else if (token === '(') {
                depth++;
            } else if (token === ')') {
                depth--;
                if (depth < 0) {
                    note('There is a closing bracket without an opening one.');
                }
            } else if (!FX_OPERATOR.test(token)) {
                cls = 'fx-op fx-bad';
                note(`"${token}" cannot be used in a formula.`);
            }
            segs.push({ key: n++, text, cls, title });
        });
        if (depth > 0) {
            note('A bracket is not closed.');
        }
        return { segs, problem };
    }

    // ----- Formula suggestions -----

    fx;
    pendingCaret;

    /** What can be typed at the caret: fields (and related records), calculated values above, and functions. */
    suggestFor(value, caret, index) {
        const before = value.substring(0, caret);
        const match = /[A-Za-z_][A-Za-z0-9_.:]*$/.exec(before);
        if (!match) {
            return null;
        }
        const fragment = match[0];
        const start = caret - fragment.length;
        const items = [];
        if (fragment.toLowerCase().startsWith('calc:') || fragment.toLowerCase() === 'calc') {
            const term = fragment.substring(5).toLowerCase();
            this.body.calculations
                .slice(0, index)
                .filter((c) => c.name && c.name.toLowerCase().startsWith(term))
                .forEach((c) => items.push({ label: c.name, detail: 'Calculated value', insert: 'calc:' + c.name }));
            return { start, items };
        }
        const dot = fragment.lastIndexOf('.');
        const prefix = dot >= 0 ? fragment.substring(0, dot + 1) : '';
        const term = (dot >= 0 ? fragment.substring(dot + 1) : fragment).toLowerCase();
        let info = this.tpl ? this.infoFor(this.tpl.baseObject) : null;
        if (prefix) {
            prefix
                .slice(0, -1)
                .split('.')
                .forEach((rel) => {
                    if (!info) {
                        return;
                    }
                    const lookup = info.fields.find((f) => (f.relationshipName || '').toLowerCase() === rel.toLowerCase());
                    info = lookup ? this.infoFor(lookup.referenceTo) : null;
                    if (lookup && !info) {
                        this.loadLater(lookup.referenceTo);
                    }
                });
        }
        const matches = (label, name) => !term || label.toLowerCase().includes(term) || name.toLowerCase().startsWith(term);
        if (info) {
            info.fields
                .filter((f) => NUMERIC_TYPES.includes(f.type) && matches(f.label, f.name))
                .sort((a, b) => a.label.localeCompare(b.label))
                .slice(0, 8)
                .forEach((f) => items.push({ label: f.label, detail: f.type, insert: prefix + f.name }));
            info.fields
                .filter((f) => f.relationshipName && matches(f.label, f.relationshipName))
                .slice(0, 4)
                .forEach((f) => items.push({ label: f.label.replace(/ ID$/, '') + ' ›', detail: 'Related record', insert: prefix + f.relationshipName + '.' }));
        }
        if (!prefix) {
            this.body.calculations
                .slice(0, index)
                .filter((c) => c.name && c.name.toLowerCase().includes(term))
                .forEach((c) => items.push({ label: c.name, detail: 'Calculated value', insert: 'calc:' + c.name }));
            FX_FUNCTIONS.filter((f) => f.name.toLowerCase().startsWith(term)).forEach((f) => items.push({ label: f.name, detail: f.hint, insert: f.name + '(' }));
        }
        return { start, items: items.slice(0, 10) };
    }

    showSuggestions(input) {
        const index = Number(input.dataset.index);
        const found = this.suggestFor(input.value, input.selectionStart, index);
        if (!found || !found.items.length) {
            this.fx = undefined;
            return;
        }
        this.fx = {
            index,
            start: found.start,
            caret: input.selectionStart,
            active: 0,
            items: found.items.map((item, i) => ({ ...item, key: item.insert, i, cls: i === 0 ? 'fx-item on' : 'fx-item' }))
        };
    }

    handleFormulaInput(event) {
        const input = event.target;
        const index = Number(input.dataset.index);
        const value = input.value;
        this.mutate((body) => {
            if (body.calculations[index]) {
                body.calculations[index].expression = value;
            }
        });
        this.showSuggestions(input);
    }

    handleFormulaKey(event) {
        if (!this.fx || !this.fx.items.length) {
            return;
        }
        const count = this.fx.items.length;
        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault();
            const active = (this.fx.active + (event.key === 'ArrowDown' ? 1 : count - 1)) % count;
            this.fx = { ...this.fx, active, items: this.fx.items.map((item) => ({ ...item, cls: item.i === active ? 'fx-item on' : 'fx-item' })) };
        } else if (event.key === 'Enter' || event.key === 'Tab') {
            event.preventDefault();
            this.pickSuggestion(this.fx.items[this.fx.active]);
        } else if (event.key === 'Escape') {
            this.fx = undefined;
        }
    }

    handleFormulaBlur() {
        // A click on a suggestion is handled on mousedown, before the box loses focus.
        this.fx = undefined;
    }

    handleSuggestPick(event) {
        event.preventDefault();
        const i = Number(event.currentTarget.dataset.i);
        if (this.fx) {
            this.pickSuggestion(this.fx.items[i]);
        }
    }

    pickSuggestion(item) {
        const { index, start, caret } = this.fx;
        const calc = this.body.calculations[index];
        if (!item || !calc) {
            return;
        }
        const value = calc.expression || '';
        const next = value.substring(0, start) + item.insert + value.substring(caret);
        this.mutate((body) => {
            body.calculations[index].expression = next;
        });
        this.pendingCaret = { index, pos: start + item.insert.length };
        // Keep suggesting while a related record's fields are being chosen.
        this.fx = undefined;
        if (item.insert.endsWith('.')) {
            const found = this.suggestFor(next, start + item.insert.length, index);
            if (found && found.items.length) {
                this.fx = { index, start: found.start, caret: start + item.insert.length, active: 0, items: found.items.map((it, i) => ({ ...it, key: it.insert, i, cls: i === 0 ? 'fx-item on' : 'fx-item' })) };
            }
        }
    }

    // ----- Live results for a sample record -----

    calcPreview;
    calcTimer;

    handleCalcRecord(event) {
        this.previewRecordId = event.detail.recordId;
        this.calcPreview = undefined;
        this.refreshCalcValues();
    }

    scheduleCalcRefresh() {
        if (!this.previewRecordId) {
            return;
        }
        clearTimeout(this.calcTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.calcTimer = setTimeout(() => this.refreshCalcValues(), 700);
    }

    async refreshCalcValues() {
        if (!this.previewRecordId || !this.tpl) {
            return;
        }
        // Only the newest request may update the read-out, so a slow older answer never overwrites a newer one.
        const ticket = (this.calcTicket = (this.calcTicket || 0) + 1);
        let answer;
        try {
            answer = await calcValues({ bodyJson: JSON.stringify(this.body), baseObject: this.tpl.baseObject, recordId: this.previewRecordId });
        } catch (e) {
            answer = { ok: false, values: {}, message: this.messageOf(e) };
        }
        if (ticket === this.calcTicket) {
            this.calcPreview = answer;
        }
    }

    get calcPreviewProblem() {
        return this.calcPreview && this.calcPreview.ok === false ? this.calcPreview.message : '';
    }

    get calcNoRecord() {
        return !this.previewRecordId;
    }

    get fxHelp() {
        return 'Type a field name or label and pick it from the list. Use + − * / and brackets, calc:Name for a value worked out above, and ' + FX_FUNCTIONS.map((f) => f.name).join(', ') + '.';
    }

    get sortOptions() {
        const info = this.tableObject ? this.infoFor(this.tableObject) : null;
        if (!info) {
            return null;
        }
        const options = [{ label: 'Keep the list order', value: '' }].concat(
            info.fields
                .filter((f) => f.type !== 'Reference')
                .map((f) => ({ label: f.label, value: f.name }))
                .sort((a, b) => a.label.localeCompare(b.label))
        );
        const current = this.sel && this.sel.orderBy;
        if (current && !options.some((o) => o.value === current)) {
            options.splice(1, 0, { label: current, value: current });
        }
        return options;
    }

    get hasSortOptions() {
        return !!this.sortOptions;
    }

    get calcOptions() {
        return this.body.calculations.filter((c) => c.name).map((c) => ({ label: c.name, value: c.name }));
    }

    get sourceOptions() {
        const info = this.tpl ? this.infoFor(this.tpl.baseObject) : null;
        const options = info ? info.children.map((c) => ({ label: `${c.name} (${c.childObject})`, value: c.name })) : [];
        options.sort((a, b) => a.label.localeCompare(b.label));
        const current = this.sel && this.sel.source;
        if (current && !options.some((o) => o.value === current)) {
            options.unshift({ label: current, value: current });
        }
        return options;
    }

    // ---------- Field picker ----------

    get pickerMode() {
        return this.selIsTable ? 'column' : 'token';
    }

    get pickerRootObject() {
        if (!this.tpl) {
            return null;
        }
        return this.selIsTable ? this.tableObject : this.tpl.baseObject;
    }

    get pickerObject() {
        return this.pickerPath.length ? this.pickerPath[this.pickerPath.length - 1].object : this.pickerRootObject;
    }

    get pickerPrefix() {
        return this.pickerPath.map((p) => p.rel + '.').join('');
    }

    get pickerTitle() {
        const root = this.infoFor(this.pickerRootObject);
        const crumbs = [root ? root.label : this.pickerRootObject || ''].concat(this.pickerPath.map((p) => p.label));
        return crumbs.join(' › ');
    }

    get pickerHint() {
        if (this.selIsTable) {
            return this.tableObject ? 'Click a field to add it as a column.' : 'Choose where the rows come from in Settings first, then pick columns here.';
        }
        if (this.selIsTextual || this.selIsTerms) {
            return 'Click a field to add it to the selected block.';
        }
        return 'Click a field to add it to the box you last clicked in Settings, or to start a new text block. Click a list to add it as a table.';
    }

    get canGoBack() {
        return this.pickerPath.length > 0;
    }

    get canDrill() {
        return this.pickerPath.length < 4;
    }

    get pickerFields() {
        const info = this.infoFor(this.pickerObject);
        if (!info) {
            return [];
        }
        const term = this.search.trim().toLowerCase();
        const prefix = this.pickerPrefix;
        return info.fields
            // Lookup fields hold raw record IDs; the related record's own fields are under "Related records".
            .filter((f) => f.type !== 'Reference')
            .filter((f) => !term || f.label.toLowerCase().includes(term) || f.name.toLowerCase().includes(term))
            .sort((a, b) => a.label.localeCompare(b.label))
            .slice(0, PICKER_LIMIT)
            .map((f) => ({ key: f.name, label: f.label, type: f.type, path: prefix + f.name }));
    }

    get pickerLookups() {
        const info = this.infoFor(this.pickerObject);
        if (!info || !this.canDrill) {
            return [];
        }
        const term = this.search.trim().toLowerCase();
        const lookups = info.fields
            .filter((f) => f.relationshipName && (!term || f.label.toLowerCase().includes(term) || f.relationshipName.toLowerCase().includes(term)))
            .map((f) => ({ key: f.name, label: f.label.replace(/ ID$/, ''), rel: f.relationshipName, object: f.referenceTo }));
        // Two lookups can share a label (e.g. two fields pointing at the same object): tell them apart by field.
        const counts = {};
        lookups.forEach((l) => {
            counts[l.label] = (counts[l.label] || 0) + 1;
        });
        return lookups
            .map((l) => ({ ...l, label: counts[l.label] > 1 ? `${l.label} (${l.rel})` : l.label }))
            .sort((a, b) => a.label.localeCompare(b.label));
    }

    get hasLookups() {
        return this.pickerLookups.length > 0;
    }

    get pickerLists() {
        if (this.selIsTable || this.pickerPath.length > 1) {
            return [];
        }
        const info = this.infoFor(this.pickerObject);
        if (!info) {
            return [];
        }
        const term = this.search.trim().toLowerCase();
        const prefix = this.pickerPrefix;
        return info.children
            .filter((c) => this.showAllLists || !NOISE_LISTS.test(c.name))
            .filter((c) => !term || c.name.toLowerCase().includes(term) || (c.label || '').toLowerCase().includes(term))
            .map((c) => ({ key: c.name, label: c.label || c.name, detail: c.name, source: prefix + c.name }))
            .sort((a, b) => a.label.localeCompare(b.label))
            .slice(0, PICKER_LIMIT);
    }

    get hasLists() {
        return this.pickerLists.length > 0;
    }

    get showListSection() {
        if (this.selIsTable || this.pickerPath.length > 1) {
            return false;
        }
        const info = this.infoFor(this.pickerObject);
        return !!info && info.children.length > 0;
    }

    handleSearch(event) {
        this.search = event.detail.value || '';
    }

    async handleDrill(event) {
        const { rel, object, label } = event.currentTarget.dataset;
        await this.run(async () => {
            await this.ensureObject(object);
            this.pickerPath = [...this.pickerPath, { rel, object, label }];
            this.search = '';
        });
    }

    handleBack() {
        this.pickerPath = this.pickerPath.slice(0, -1);
    }

    handlePickList(event) {
        this.addBlock('table', { source: event.currentTarget.dataset.source });
    }

    handlePick(event) {
        const { path, label, type } = event.currentTarget.dataset;
        if (this.pickerMode === 'column') {
            this.mutate((body) => {
                const block = this.blockIn(body);
                block.columns = block.columns || [];
                const column = { header: label, field: path };
                if (NUMERIC_TYPES.includes(type)) {
                    column.align = 'right';
                }
                block.columns.push(column);
            });
            return;
        }
        let token = `{{${path}}}`;
        const block = this.body.blocks.find((b) => b.id === this.selectedId);
        if (this.focus.prop === 'fileNamePattern' && !block) {
            this.fileNamePattern = (this.fileNamePattern || '') + token;
            this.dirty = true;
            return;
        }
        if (!block && this.focus.prop && this.focus.prop.startsWith('signer:')) {
            const prop = this.focus.prop.substring(7);
            const index = Number(this.focus.index);
            this.mutate((body) => {
                if (body.signers && body.signers[index]) {
                    body.signers[index][prop] = (body.signers[index][prop] || '') + token;
                }
            });
            return;
        }
        if (!block && this.focus.prop && this.focus.prop.startsWith('msg:')) {
            const key = this.focus.prop.substring(4);
            this.mutate((body) => {
                body.messages = body.messages || {};
                body.messages[key] = (body.messages[key] || '') + token;
            });
            return;
        }
        const pageSections = { headerText: 'header', footerText: 'footer', watermarkText: 'watermark' };
        if (!block && pageSections[this.focus.prop]) {
            const section = pageSections[this.focus.prop];
            this.mutate((body) => {
                body.page = body.page || {};
                body.page[section] = body.page[section] || {};
                body.page[section].text = (body.page[section].text || '') + token;
            });
            return;
        }
        if (block && (block.type === 'text' || block.type === 'heading')) {
            const prop = this.focus.prop === 'elseText' ? 'elseText' : 'text';
            // Optionally wrap the field in a condition so it only prints when the condition holds.
            if (this.wrapMode === 'filled') {
                token = `{{#if ${path}}}${token}{{/if}}`;
            } else if (this.wrapMode && this.wrapMode.startsWith('cond:')) {
                token = `{{#if ${this.wrapMode}}}${token}{{/if}}`;
            }
            this.mutate((body) => {
                const target = this.blockIn(body);
                const current = target[prop] || '';
                if (target.rich && prop === 'text') {
                    // Keep the token inside the last paragraph rather than after it.
                    const at = current.lastIndexOf('</p>');
                    target[prop] = at >= 0 ? current.slice(0, at) + token + current.slice(at) : current + `<p>${token}</p>`;
                } else {
                    target[prop] = current + token;
                }
            });
            return;
        }
        if (block && block.type === 'terms') {
            const index = this.focus.prop === 'itemText' ? Number(this.focus.index) : (block.items || []).length - 1;
            this.mutate((body) => {
                const target = this.blockIn(body);
                target.items = target.items || [];
                if (!target.items[index]) {
                    target.items.push({ id: this.uid(), text: '' });
                }
                const item = target.items[index] || target.items[target.items.length - 1];
                item.text = (item.text || '') + token;
            });
            return;
        }
        this.addBlock('text', { text: token });
    }

    // ---------- Preview ----------

    get languageOptions() {
        const options = [{ label: 'Default language', value: '' }];
        (this.languages || '')
            .split(',')
            .map((l) => l.trim())
            .filter((l) => l && (!this.tpl || l !== this.tpl.defaultLanguage))
            .forEach((l) => options.push({ label: l, value: l }));
        return options;
    }

    get hasLanguages() {
        return this.languageOptions.length > 1;
    }

    handlePreviewRecord(event) {
        this.previewRecordId = event.detail.recordId;
        if (this.previewRecordId) {
            this.refreshPreview();
        } else {
            this.previewHtml = undefined;
        }
    }

    handlePreviewLanguage(event) {
        this.previewLanguage = event.detail.value;
        if (this.previewRecordId) {
            this.refreshPreview();
        }
    }

    async refreshPreview() {
        this.busy = true;
        this.previewError = undefined;
        try {
            this.previewHtml = await previewBody({
                bodyJson: JSON.stringify(this.body),
                baseObject: this.tpl.baseObject,
                recordId: this.previewRecordId,
                versionId: this.tpl.versionId,
                language: this.previewLanguage || null
            });
        } catch (e) {
            this.previewHtml = undefined;
            this.previewError = this.messageOf(e);
        } finally {
            this.busy = false;
        }
    }

    get showPreviewHint() {
        return !this.previewRecordId && !this.previewError;
    }

    // ---------- Translations ----------

    get translationLanguages() {
        return this.languageOptions.filter((o) => o.value);
    }

    get noTranslationLanguages() {
        return this.translationLanguages.length === 0;
    }

    get transRows() {
        return this.transParts.map((p, index) => ({ ...p, index, key: p.blockId + '|' + p.part }));
    }

    get hasTransRows() {
        return this.transParts.length > 0;
    }

    async handleTransLanguage(event) {
        this.transLanguage = event.detail.value;
        await this.loadTranslations();
    }

    async loadTranslations() {
        await this.run(async () => {
            if (this.dirty) {
                await this.save();
            }
            this.transParts = await getTranslations({ versionId: this.tpl.versionId, language: this.transLanguage });
        });
    }

    handleTransText(event) {
        const index = Number(event.target.dataset.index);
        this.transParts = this.transParts.map((p, i) => (i === index ? { ...p, translated: event.detail.value, outOfDate: false } : p));
    }

    async handleSaveTranslations() {
        await this.run(async () => {
            await saveTranslations({ versionId: this.tpl.versionId, language: this.transLanguage, itemsJson: JSON.stringify(this.transParts) });
            this.transParts = await getTranslations({ versionId: this.tpl.versionId, language: this.transLanguage });
            this.toast('Translations saved', `Saved for ${this.transLanguage} on version ${this.tpl.versionNumber}.`);
        });
    }
}
