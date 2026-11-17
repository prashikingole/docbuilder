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

const TOKEN = /\{\{\s*([^}|]+?)\s*(?:\|\s*([A-Za-z]+)\s*)?\}\}/g;
const TYPE_LABELS = { heading: 'Heading', text: 'Text', table: 'Table', terms: 'Terms', image: 'Image', signature: 'Signature', pagebreak: 'Page break' };
const FILE_URL = '/sfc/servlet.shepherd/version/download/';
const NOISE_LISTS = /(History|Histories|Feed|Feeds|Share|Shares|ChangeEvent|Tag|Tags)$|^(ActivityHistories|OpenActivities|AttachedContentDocuments|AttachedContentNotes|CombinedAttachments|ContentDocumentLinks|ContentDistributions|Attachments|Notes|NotesAndAttachments|Emails|EmailMessageRelations|EventRelations|TaskRelations|ProcessInstances|ProcessSteps|ProcessExceptions|RecordActions|RecordActionHistories|RecordAssociatedGroups|TopicAssignments|FeedSubscriptionsForEntity|UserRecordAccess|FlowOrchestrationWorkItems|FlowExecutionErrorEvents|NetworkActivityAudits|CollaborationGroupRecords|DuplicateRecordItems|PendingServiceRoutings|MessagingSessions|SurveySubjectEntities|ContactRequests|AIRecordInsights|AIInsightValues|ContentVersions|LookedUpFromActivities|Personas|WorkOrders|ServiceAppointments|Swarms|SwarmMembers|ConversationEntries|GptPromptEvents|AppUsageAssignments|ScorecardAssociations|AccountUserTerritory2Views)$/;
const PAGE_SHAPES = { a4: 1.414, letter: 1.294, legal: 1.647 };
const PAGE_PADDING = { narrow: '1.5rem', normal: '2.5rem', wide: '3.75rem' };
const OP_LABELS = { eq: '=', ne: '≠', gt: '>', ge: '≥', lt: '<', le: '≤', contains: 'contains', blank: 'is blank', notBlank: 'is not blank' };
const NUMERIC_TYPES = ['Currency', 'Double', 'Integer', 'Percent', 'Long'];
const PICKER_LIMIT = 150;

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
    }

    renderedCallback() {
        const host = this.template.querySelector('.preview-body');
        if (host && this.renderedPreview !== this.previewHtml) {
            // The HTML comes from our own renderer, which escapes every data value.
            // eslint-disable-next-line @lwc/lwc/no-inner-html
            host.innerHTML = this.previewHtml || '';
            this.renderedPreview = this.previewHtml;
        }
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
        this.body = body;
        this.dirty = true;
        this.health = undefined;
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
    }

    toggleNew() {
        this.showNew = !this.showNew;
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

    get isPanelSigners() {
        return this.settingsPanel === 'signers';
    }

    // ---------- Signers and signature blocks ----------

    get signerRows() {
        return (this.body.signers || []).map((s, index) => ({ ...s, index, num: index + 1 }));
    }

    get noSigners() {
        return !(this.body.signers || []).length;
    }

    /** How a signature block is drawn on the page: one signing area per signer. */
    get signatureAreas() {
        const signers = this.body.signers || [];
        if (!signers.length) {
            return [{ key: 0, role: 'Signature', segs: [] }];
        }
        return signers.map((s, index) => ({ key: index, role: s.role || `Signer ${index + 1}`, segs: this.segments(s.name) }));
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
        const titles = { template: 'Name and languages', page: 'Page setup', headerfooter: 'Header, footer, watermark', calc: 'Calculated values', signers: 'Signers' };
        return titles[this.settingsPanel] || 'Template';
    }

    // ---------- Canvas ----------

    get blockViews() {
        const count = this.body.blocks.length;
        return this.body.blocks.map((b, index) => {
            const type = b.type || 'text';
            const rule = this.ruleSummary(b.showIf);
            return {
                id: b.id,
                cls: 'block' + (b.id === this.selectedId ? ' selected' : ''),
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
                columns: (b.columns || []).map((c, i) => ({ key: i, header: c.header || c.field, field: c.field, cls: c.align ? 'cell align-' + c.align : 'cell' })),
                noColumns: !(b.columns || []).length,
                rowRule: this.ruleSummary(b.rowFilter).replace('Show only if', 'Only rows where'),
                totals: (b.totals || []).map((t, i) => ({ key: i, label: t.label, calc: t.calc })),
                title: b.title,
                items: (b.items || []).map((item, i) => {
                    const itemRule = this.ruleSummary(item.showIf);
                    return { key: item.id || i, num: i + 1 + '.', segs: this.segments(item.text), rule: itemRule, hasRule: !!itemRule };
                }),
                clauseCategory: b.clauseCategory,
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
            columns: (block.columns || []).map((c, index) => ({ ...c, index, align: c.align || '', format: c.format || '' })),
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
            const holder = target === 'item' ? block.items[index] : block;
            const key = target === 'rowFilter' ? 'rowFilter' : 'showIf';
            if (rule) {
                holder[key] = rule;
            } else {
                delete holder[key];
            }
        });
    }

    listOf(body, listName) {
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
            if (value === '' || value === null || value === undefined) {
                delete rows[index][prop];
            } else {
                rows[index][prop] = value;
            }
        });
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
            signers: { role: '', name: '', email: '' }
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
        return this.body.calculations.map((c, index) => ({
            ...c,
            index,
            type: c.type || 'count',
            format: c.format || '',
            isFormula: c.type === 'formula',
            isRollup: c.type !== 'formula',
            needsField: c.type !== 'formula' && c.type !== 'count' && !!c.type
        }));
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
        const token = `{{${path}}}`;
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
