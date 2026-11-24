import { LightningElement, api } from 'lwc';
import describeObject from '@salesforce/apex/DocBuilderDesignerController.describeObject';

const OPS = [
    { label: 'equals', value: 'eq' },
    { label: 'does not equal', value: 'ne' },
    { label: 'is greater than', value: 'gt' },
    { label: 'is at least', value: 'ge' },
    { label: 'is less than', value: 'lt' },
    { label: 'is at most', value: 'le' },
    { label: 'contains', value: 'contains' },
    { label: 'is blank', value: 'blank' },
    { label: 'is not blank', value: 'notBlank' }
];
const NUMERIC = ['Currency', 'Double', 'Integer', 'Percent', 'Long'];
const RELATED = '>';

// Object descriptions are shared by every rule editor on the page, so each object is fetched once.
const described = new Map();

function describe(objectName) {
    const key = objectName.toLowerCase();
    if (!described.has(key)) {
        described.set(
            key,
            describeObject({ objectName }).catch((e) => {
                described.delete(key);
                throw e;
            })
        );
    }
    return described.get(key);
}

/**
 * Edits one rule: { logic, conditions: [{ field, op, value }] }.
 * Fields are picked from the object's own fields, one level of related records and calculated values,
 * so a rule cannot name a field that does not exist. Fires "rulechange" with detail.rule (null when empty).
 */
export default class DocBuilderRule extends LightningElement {
    ops = OPS;
    conditions = [];
    logic = '';
    info;
    related = {};
    _objectName;
    _calcNames = [];

    /** API name of the object whose fields the rule tests, e.g. Opportunity, or OpportunityLineItem for a row filter. */
    @api
    get objectName() {
        return this._objectName;
    }
    set objectName(value) {
        if (value === this._objectName) {
            return;
        }
        this._objectName = value;
        this.info = undefined;
        this.related = {};
        if (value) {
            describe(value)
                .then((info) => {
                    if (this._objectName === value) {
                        this.info = info;
                        this.loadRelated();
                    }
                })
                .catch(() => {
                    this.info = undefined;
                });
        }
    }

    /** Calculated value names offered as calc:Name. */
    @api
    get calcNames() {
        return this._calcNames;
    }
    set calcNames(value) {
        this._calcNames = Array.isArray(value) ? value : [];
    }

    /** Calculated values that are text (Text by value), so they get a text value box rather than a number box. */
    @api
    get textCalcs() {
        return this._textCalcs || [];
    }
    set textCalcs(value) {
        this._textCalcs = Array.isArray(value) ? value : [];
    }

    /** Apex check names offered as apex:Name (yes/no answers from code). */
    @api
    get apexChecks() {
        return this._apexChecks || [];
    }
    set apexChecks(value) {
        this._apexChecks = Array.isArray(value) ? value : [];
    }

    /** The type of an Apex variable (Boolean, Number, Text or Date) as the rule editor's value control needs it. */
    apexType(name) {
        const found = this.apexChecks.find((c) => (typeof c === 'string' ? c : c.name) === name);
        const type = found && typeof found !== 'string' ? found.type : 'Boolean';
        return { Number: 'Double', Text: 'String', Date: 'Date', Boolean: 'Boolean' }[type] || 'String';
    }

    @api
    get rule() {
        return this.build();
    }
    set rule(value) {
        const conditions = value && Array.isArray(value.conditions) ? value.conditions : [];
        this.conditions = conditions.map((c) => ({ field: c.field || '', op: c.op || 'eq', value: c.value == null ? '' : String(c.value) }));
        this.logic = (value && value.logic) || '';
        this.loadRelated();
    }

    /** Fetches the related objects already used by conditions, so their fields can be listed. */
    loadRelated() {
        if (!this.info) {
            return;
        }
        this.conditions.forEach((c) => {
            const rel = c.field && c.field.includes('.') ? c.field.split('.')[0] : null;
            if (rel) {
                this.ensureRelated(rel);
            }
        });
    }

    ensureRelated(rel) {
        const lookup = this.info && this.info.fields.find((f) => f.relationshipName === rel);
        if (!lookup || this.related[rel]) {
            return;
        }
        describe(lookup.referenceTo)
            .then((info) => {
                this.related = { ...this.related, [rel]: info };
            })
            .catch(() => {
                // The field list falls back to showing the current value.
            });
    }

    get picking() {
        return !!this.info;
    }

    fieldOptions() {
        const fields = this.info.fields
            .filter((f) => f.type !== 'Reference')
            .map((f) => ({ label: f.label, value: f.name }))
            .sort((a, b) => a.label.localeCompare(b.label));
        const lookups = this.info.fields
            .filter((f) => f.relationshipName)
            .map((f) => ({ label: f.label.replace(/ ID$/, '') + ' ›', value: RELATED + f.relationshipName }))
            .sort((a, b) => a.label.localeCompare(b.label));
        const calcs = this._calcNames.map((n) => ({ label: 'Calculated: ' + n, value: 'calc:' + n }));
        const checks = this.apexChecks.map((c) => {
            const name = typeof c === 'string' ? c : c.name;
            return { label: 'Apex: ' + name, value: 'apex:' + name };
        });
        return [...checks, ...calcs, ...fields, ...lookups];
    }

    fieldInfo(info, name) {
        return info ? info.fields.find((f) => f.name.toLowerCase() === (name || '').toLowerCase()) : null;
    }

    get rows() {
        const base = this.picking ? this.fieldOptions() : [];
        return this.conditions.map((c, index) => {
            const row = { ...c, index, num: index + 1, needsValue: c.op !== 'blank' && c.op !== 'notBlank' };
            if (!this.picking) {
                return { ...row, textField: true, textValue: row.needsValue };
            }
            const parts = (c.field || '').split('.');
            const isApex = (c.field || '').startsWith('apex:');
            const isRelated = parts.length === 2 && !c.field.startsWith('calc:') && !isApex;
            const top = isRelated ? RELATED + parts[0] : c.field;
            const options = [...base];
            if (top && !options.some((o) => o.value === top)) {
                options.unshift({ label: c.field + ' (not found on this object)', value: top });
            }
            let field = isRelated ? null : this.fieldInfo(this.info, c.field);
            let relOptions = [];
            let relValue = '';
            if (isRelated) {
                const relInfo = this.related[parts[0]];
                relValue = parts[1];
                if (relInfo) {
                    relOptions = relInfo.fields
                        .filter((f) => f.type !== 'Reference')
                        .map((f) => ({ label: f.label, value: f.name }))
                        .sort((a, b) => a.label.localeCompare(b.label));
                    field = this.fieldInfo(relInfo, parts[1]);
                }
                if (relValue && !relOptions.some((o) => o.value === relValue)) {
                    relOptions.unshift({ label: relValue, value: relValue });
                }
            }
            let type = field ? field.type : c.field && c.field.startsWith('calc:') ? 'Double' : 'String';
            if (c.field && c.field.startsWith('calc:') && this.textCalcs.includes(c.field.substring(5))) {
                // Text by value results are text.
                type = 'String';
            }
            if (isApex) {
                type = this.apexType(c.field.substring(5));
            }
            const picklist = field && Array.isArray(field.values) && field.values.length ? field.values : null;
            const valueOptions = picklist ? picklist.map((v) => ({ label: v, value: v })) : null;
            if (valueOptions && c.value && !picklist.includes(c.value)) {
                valueOptions.unshift({ label: c.value, value: c.value });
            }
            const kind = !row.needsValue ? '' : valueOptions ? 'list' : type === 'Boolean' ? 'bool' : type === 'Date' ? 'date' : NUMERIC.includes(type) ? 'number' : 'text';
            return {
                ...row,
                fieldOptions: options,
                top,
                isRelated,
                relOptions,
                relValue,
                relPlaceholder: 'Choose a field of ' + parts[0],
                valueOptions,
                boolOptions: [
                    { label: 'Yes (ticked)', value: 'true' },
                    { label: 'No (not ticked)', value: 'false' }
                ],
                isList: kind === 'list',
                isBool: kind === 'bool',
                isDate: kind === 'date',
                isNumber: kind === 'number',
                isText: kind === 'text'
            };
        });
    }

    get hasRows() {
        return this.conditions.length > 0;
    }

    build() {
        if (!this.conditions.length) {
            return null;
        }
        const rule = { conditions: this.conditions.map((c) => ({ ...c })) };
        if (this.logic && this.logic.trim()) {
            rule.logic = this.logic.trim();
        }
        return rule;
    }

    notify() {
        this.dispatchEvent(new CustomEvent('rulechange', { detail: { rule: this.build() } }));
    }

    update(index, change) {
        this.conditions = this.conditions.map((c, i) => (i === index ? { ...c, ...change } : c));
        this.notify();
    }

    handleChange(event) {
        const index = Number(event.target.dataset.index);
        this.update(index, { [event.target.dataset.prop]: event.detail.value });
    }

    handleField(event) {
        const index = Number(event.target.dataset.index);
        const value = event.detail.value;
        if (value.startsWith(RELATED)) {
            // A related record: its field is chosen in the second list.
            const rel = value.substring(1);
            this.ensureRelated(rel);
            this.update(index, { field: rel + '.', value: '' });
            return;
        }
        const field = this.fieldInfo(this.info, value);
        const change = { field: value, value: '' };
        if ((field && field.type === 'Boolean') || (value.startsWith('apex:') && this.apexType(value.substring(5)) === 'Boolean')) {
            change.value = 'true';
        }
        this.update(index, change);
    }

    handleRelField(event) {
        const index = Number(event.target.dataset.index);
        const rel = this.conditions[index].field.split('.')[0];
        this.update(index, { field: rel + '.' + event.detail.value, value: '' });
    }

    handleLogic(event) {
        this.logic = event.detail.value;
        this.notify();
    }

    handleAdd() {
        this.conditions = [...this.conditions, { field: '', op: 'eq', value: '' }];
        this.notify();
    }

    handleRemove(event) {
        const index = Number(event.target.dataset.index);
        this.conditions = this.conditions.filter((c, i) => i !== index);
        if (!this.conditions.length) {
            this.logic = '';
        }
        this.notify();
    }
}
