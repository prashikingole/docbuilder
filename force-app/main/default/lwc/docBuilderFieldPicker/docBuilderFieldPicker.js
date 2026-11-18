import { LightningElement, api } from 'lwc';
import describeObject from '@salesforce/apex/DocBuilderDesignerController.describeObject';

const RELATED = '>';
export const AS_TEXT = '__text';
export const LEAVE_OUT = '__drop';

// Object descriptions are shared by every picker on the page, so each object is fetched once.
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
 * Picks one field path, such as Amount or Account.Name, from lists instead of free typing.
 * With allow-skip, it also offers "Print the name as text" and "Leave it out".
 * Fires "change" with detail.value: the path, AS_TEXT or LEAVE_OUT.
 */
export default class DocBuilderFieldPicker extends LightningElement {
    @api label = 'Field';
    @api variant = 'label-hidden';
    @api allowSkip = false;

    info;
    relatedInfo;
    _objectName;
    _value = '';

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

    @api
    get value() {
        return this._value;
    }
    set value(v) {
        this._value = v || '';
        this.loadRelated();
    }

    get parts() {
        return this._value && !this._value.startsWith('__') ? this._value.split('.') : [];
    }

    /** A two-part path whose first part is a lookup on this object, e.g. Account.Name. */
    get relName() {
        const parts = this.parts;
        if (parts.length !== 2 || !this.info) {
            return null;
        }
        return this.info.fields.some((f) => f.relationshipName === parts[0]) ? parts[0] : null;
    }

    loadRelated() {
        const rel = this.relName;
        if (!rel) {
            this.relatedInfo = undefined;
            return;
        }
        const lookup = this.info.fields.find((f) => f.relationshipName === rel);
        if (this.relatedInfo && this.relatedInfo.rel === rel) {
            return;
        }
        describe(lookup.referenceTo)
            .then((info) => {
                if (this.relName === rel) {
                    this.relatedInfo = { rel, info };
                }
            })
            .catch(() => {
                this.relatedInfo = undefined;
            });
    }

    get top() {
        if (!this._value) {
            return '';
        }
        if (this._value.startsWith('__')) {
            return this._value;
        }
        return this.relName ? RELATED + this.relName : this._value;
    }

    get options() {
        const options = [];
        if (this.allowSkip) {
            options.push({ label: 'Print the name as text', value: AS_TEXT }, { label: 'Leave it out', value: LEAVE_OUT });
        }
        if (!this.info) {
            if (this._value && !this._value.startsWith('__')) {
                options.push({ label: this._value, value: this._value });
            }
            return options;
        }
        const fields = this.info.fields
            .filter((f) => f.type !== 'Reference')
            .map((f) => ({ label: f.label, value: f.name }))
            .sort((a, b) => a.label.localeCompare(b.label));
        const lookups = this.info.fields
            .filter((f) => f.relationshipName)
            .map((f) => ({ label: f.label.replace(/ ID$/, '') + ' ›', value: RELATED + f.relationshipName }))
            .sort((a, b) => a.label.localeCompare(b.label));
        const top = this.top;
        // A deeper suggestion (e.g. Account.Owner.Name) is offered as it is.
        if (top && !top.startsWith('__') && !top.startsWith(RELATED) && !fields.some((f) => f.value === top)) {
            options.push({ label: top + (this.parts.length > 2 ? ' (suggested)' : ' (not found)'), value: top });
        }
        return [...options, ...fields, ...lookups];
    }

    get isRelated() {
        return !!this.relName;
    }

    get relOptions() {
        const parts = this.parts;
        const options = this.relatedInfo
            ? this.relatedInfo.info.fields
                  .filter((f) => f.type !== 'Reference')
                  .map((f) => ({ label: f.label, value: f.name }))
                  .sort((a, b) => a.label.localeCompare(b.label))
            : [];
        if (parts[1] && !options.some((o) => o.value === parts[1])) {
            options.unshift({ label: parts[1], value: parts[1] });
        }
        return options;
    }

    get relValue() {
        return this.parts[1] || '';
    }

    get relPlaceholder() {
        return 'Choose a field of ' + (this.relName || 'the related record');
    }

    notify(value) {
        this._value = value;
        this.loadRelated();
        this.dispatchEvent(new CustomEvent('change', { detail: { value } }));
    }

    handleTop(event) {
        const value = event.detail.value;
        if (value.startsWith(RELATED)) {
            // A related record: its field is chosen in the second list.
            this._value = value.substring(1) + '.';
            this.relatedInfo = undefined;
            this.loadRelatedFor(value.substring(1));
            return;
        }
        this.notify(value);
    }

    loadRelatedFor(rel) {
        const lookup = this.info.fields.find((f) => f.relationshipName === rel);
        describe(lookup.referenceTo).then((info) => {
            this.relatedInfo = { rel, info };
        });
    }

    handleRel(event) {
        this.notify(this.relName + '.' + event.detail.value);
    }
}
