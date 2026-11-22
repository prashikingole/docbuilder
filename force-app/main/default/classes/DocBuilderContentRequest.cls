/** What a Custom content block asks a DocBuilderContentProvider for. New members may be added; existing ones will not change. */
global with sharing class DocBuilderContentRequest {
    /** The record the document is generated for. Null when the designer checks the block without a record. */
    global Id recordId;
    /** The template's object, for example Opportunity. */
    global String objectName;
    /** The text typed in the block's Settings box, for example JSON the class understands. */
    global String settings;
    /** The language the document is generated in, for example en or fr. */
    global String language;
}
