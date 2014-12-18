%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2014, 2600Hz INC
%%% @doc
%%%
%%% @end
%%% @contributors:
%%%   Karl Anderson
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(cb_notifications).

-export([init/0
         ,authorize/1
         ,allowed_methods/0, allowed_methods/1, allowed_methods/2
         ,resource_exists/0, resource_exists/1, resource_exists/2
         ,content_types_provided/2
         ,content_types_accepted/2
         ,validate/1, validate/2, validate/3
         ,put/1
         ,post/2, post/3
         ,delete/2
        ]).

-include("../crossbar.hrl").

-define(NOTIFICATION_MIME_TYPES, [{<<"text">>, <<"html">>}
                                  ,{<<"text">>, <<"plain">>}
                                 ]).
-define(CB_LIST, <<"notifications/crossbar_listing">>).
-define(PREVIEW, <<"preview">>).

-define(MACROS, <<"macros">>).
-define(PVT_TYPE, <<"notification">>).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Initializes the bindings this module will respond to.
%% @end
%%--------------------------------------------------------------------
-spec init() -> 'ok'.
init() ->
    _ = crossbar_bindings:bind(<<"*.authorize">>, ?MODULE, 'authorize'),
    _ = crossbar_bindings:bind(<<"*.allowed_methods.notifications">>, ?MODULE, 'allowed_methods'),
    _ = crossbar_bindings:bind(<<"*.resource_exists.notifications">>, ?MODULE, 'resource_exists'),
    _ = crossbar_bindings:bind(<<"*.content_types_provided.notifications">>, ?MODULE, 'content_types_provided'),
    _ = crossbar_bindings:bind(<<"*.content_types_accepted.notifications">>, ?MODULE, 'content_types_accepted'),
    _ = crossbar_bindings:bind(<<"*.validate.notifications">>, ?MODULE, 'validate'),
    _ = crossbar_bindings:bind(<<"*.execute.put.notifications">>, ?MODULE, 'put'),
    _ = crossbar_bindings:bind(<<"*.execute.post.notifications">>, ?MODULE, 'post'),
    _ = crossbar_bindings:bind(<<"*.execute.delete.notifications">>, ?MODULE, 'delete').

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Authorizes the incoming request, returning true if the requestor is
%% allowed to access the resource, or false if not.
%% @end
%%--------------------------------------------------------------------
-spec authorize(cb_context:context()) -> boolean().
-spec authorize(cb_context:context(), ne_binary(), req_nouns()) -> boolean().
authorize(Context) ->
    authorize(Context, cb_context:auth_account_id(Context), cb_context:req_nouns(Context)).

authorize(_Context, AuthAccountId, [{<<"notifications">>, _Id}
                                    ,{<<"accounts">>, [AccountId]}
                                   ]) ->
    lager:debug("maybe authz for ~s to modify ~s in ~s", [AuthAccountId, _Id, AccountId]),
    wh_services:is_reseller(AuthAccountId)
        andalso wh_util:is_in_account_hierarchy(AuthAccountId, AccountId, 'true');
authorize(Context, AuthAccountId, [{<<"notifications">>, []}]) ->
    lager:debug("checking authz on system request to /"),
    {'ok', MasterAccountId} = whapps_util:get_master_account_id(),
    cb_context:req_verb(Context) =:= ?HTTP_GET
        orelse AuthAccountId =:= MasterAccountId;
authorize(Context, AuthAccountId, [{<<"notifications">>, _Id}]) ->
    lager:debug("maybe authz for system notification ~s", [_Id]),
    {'ok', MasterAccountId} = whapps_util:get_master_account_id(),
    cb_context:req_verb(Context) =:= ?HTTP_GET
        orelse AuthAccountId =:= MasterAccountId;
authorize(_Context, _AuthAccountId, _Nouns) -> 'false'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Given the path tokens related to this module, what HTTP methods are
%% going to be responded to.
%% @end
%%--------------------------------------------------------------------
-spec allowed_methods() -> http_methods().
-spec allowed_methods(path_token()) -> http_methods().
-spec allowed_methods(path_token(), path_token()) -> http_methods().
allowed_methods() ->
    [?HTTP_GET, ?HTTP_PUT].
allowed_methods(_) ->
    [?HTTP_GET, ?HTTP_POST, ?HTTP_DELETE].
allowed_methods(_, ?PREVIEW) ->
    [?HTTP_POST].

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Does the path point to a valid resource
%% So /notifications => []
%%    /notifications/foo => [<<"foo">>]
%%    /notifications/foo/bar => [<<"foo">>, <<"bar">>]
%% @end
%%--------------------------------------------------------------------
-spec resource_exists() -> 'true'.
-spec resource_exists(path_token()) -> 'true'.
-spec resource_exists(path_token(), path_token()) -> 'true'.
resource_exists() -> 'true'.
resource_exists(_Id) -> 'true'.
resource_exists(_Id, ?PREVIEW) -> 'true'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Add content types accepted and provided by this module
%%
%% @end
%%--------------------------------------------------------------------
-spec content_types_provided(cb_context:context(), path_token()) ->
                                    cb_context:context().
-spec content_types_provided(cb_context:context(), path_token(), http_method()) ->
                                    cb_context:context().
content_types_provided(Context, Id) ->
    content_types_provided(Context, db_id(Id), cb_context:req_verb(Context)).

content_types_provided(Context, Id, ?HTTP_GET) ->
    Context1 = read(Context, Id),
    case cb_context:resp_status(Context1) of
        'success' -> maybe_set_content_types(Context1);
        _Status -> Context1
    end;
content_types_provided(Context, Id, ?HTTP_DELETE) ->
    Context1 = read(Context, Id, 'account'),
    case cb_context:resp_status(Context1) of
        'success' -> maybe_set_content_types(Context1);
        _Status -> Context1
    end;
content_types_provided(Context, _Id, _Verb) ->
    Context.

-spec maybe_set_content_types(cb_context:context()) -> cb_context:context().
maybe_set_content_types(Context) ->
    case wh_json:get_value(<<"_attachments">>, cb_context:doc(Context)) of
        'undefined' -> Context;
        Attachments -> set_content_types(Context, Attachments)
    end.

-spec set_content_types(cb_context:context(), wh_json:object()) -> cb_context:context().
set_content_types(Context, Attachments) ->
    ContentTypes = content_types_from_attachments(Attachments),
    lager:debug("setting content types for attachments: ~p", [ContentTypes]),
    cb_context:set_content_types_provided(Context, [{'to_json', ?JSON_CONTENT_TYPES}
                                                    ,{'to_binary', ContentTypes}
                                                   ]).

-spec content_types_from_attachments(wh_json:object()) -> wh_proplist().
content_types_from_attachments(Attachments) ->
    wh_json:foldl(fun content_type_from_attachment/3, [], Attachments).

-spec content_type_from_attachment(wh_json:key(), wh_json:object(), wh_proplist()) ->
                                          wh_proplist().
content_type_from_attachment(_Name, Attachment, Acc) ->
    case wh_json:get_value(<<"content_type">>, Attachment) of
        'undefined' -> Acc;
        ContentType ->
            [list_to_tuple(
               binary:split(ContentType, <<"/">>)
              )
             | Acc
            ]
    end.

-spec content_types_accepted(cb_context:context(), path_token()) -> cb_context:context().
content_types_accepted(Context, _Id) ->
    content_types_accepted_for_upload(Context, cb_context:req_verb(Context)).

-spec content_types_accepted_for_upload(cb_context:context(), http_method()) ->
                                               cb_context:context().
content_types_accepted_for_upload(Context, ?HTTP_POST) ->
    CTA = [{'from_binary', ?NOTIFICATION_MIME_TYPES}
           ,{'from_json', ?JSON_CONTENT_TYPES}
          ],
    cb_context:set_content_types_accepted(Context, CTA);
content_types_accepted_for_upload(Context, _Verb) ->
    Context.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Check the request (request body, query string params, path tokens, etc)
%% and load necessary information.
%% /notifications mights load a list of skel objects
%% /notifications/123 might load the skel object 123
%% Generally, use crossbar_doc to manipulate the cb_context{} record
%% @end
%%--------------------------------------------------------------------
-spec validate(cb_context:context()) -> cb_context:context().
-spec validate(cb_context:context(), path_token()) -> cb_context:context().
-spec validate(cb_context:context(), path_token(), path_token()) -> cb_context:context().
validate(Context) ->
    validate_notifications(Context, cb_context:req_verb(Context)).

validate(Context, Id) ->
    validate_notification(Context, db_id(Id), cb_context:req_verb(Context)).

validate(Context, Id, ?PREVIEW) ->
    update(Context, db_id(Id)).

-spec validate_notifications(cb_context:context(), http_method()) ->
                                    cb_context:context().
validate_notifications(Context, ?HTTP_GET) ->
    summary(Context);
validate_notifications(Context, ?HTTP_PUT) ->
    create(Context).

-spec validate_notification(cb_context:context(), path_token(), http_method()) ->
                                   cb_context:context().
validate_notification(Context, Id, ?HTTP_GET) ->
    maybe_read(Context, Id);
validate_notification(Context, Id, ?HTTP_POST) ->
    maybe_update(Context, Id);
validate_notification(Context, Id, ?HTTP_DELETE) ->
    read(Context, Id, 'account').

%%--------------------------------------------------------------------
%% @public
%% @doc
%% If the HTTP verb is PUT, execute the actual action, usually a db save.
%% @end
%%--------------------------------------------------------------------
-spec put(cb_context:context()) -> cb_context:context().
put(Context) ->
    Context1 = crossbar_doc:save(Context),
    case cb_context:resp_status(Context1) of
        'success' -> leak_doc_id(Context1);
        _Status -> Context1
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% If the HTTP verb is POST, execute the actual action, usually a db save
%% (after a merge perhaps).
%% @end
%%--------------------------------------------------------------------
-spec post(cb_context:context(), path_token()) -> cb_context:context().
-spec post(cb_context:context(), path_token(), path_token()) -> cb_context:context().
post(Context, Id) ->
    case cb_context:req_files(Context) of
        [] -> do_post(Context);
        [{_FileName, FileJObj}] ->
            lager:debug("POST is for an attachment on ~s(~s)", [Id, db_id(Id)]),
            update_template(Context, db_id(Id), FileJObj)
    end.

-spec do_post(cb_context:context()) -> cb_context:context().
do_post(Context) ->
    Context1 = crossbar_doc:save(Context),
    case cb_context:resp_status(Context1) of
        'success' -> leak_doc_id(Context1);
        _Status -> Context1
    end.

post(Context, Id, ?PREVIEW) ->
    Notification = cb_context:doc(Context),

    Preview =
        props:filter_undefined(
          [{<<"To">>, wh_json:get_value(<<"to">>, Notification)}
           ,{<<"From">>, wh_json:get_value(<<"from">>, Notification)}
           ,{<<"Cc">>, wh_json:get_value(<<"cc">>, Notification)}
           ,{<<"Bcc">>, wh_json:get_value(<<"bcc">>, Notification)}
           ,{<<"Reply-To">>, wh_json:get_value(<<"reply_to">>, Notification)}
           ,{<<"Subject">>, wh_json:get_value(<<"subject">>, Notification)}
           ,{<<"HTML">>, wh_json:get_value(<<"html">>, Notification)}
           ,{<<"Text">>, wh_json:get_value(<<"plain">>, Notification)}
           ,{<<"Account-ID">>, cb_context:account_id(Context)}
           ,{<<"Account-DB">>, cb_context:account_db(Context)}
           ,{<<"Msg-ID">>, cb_context:req_id(Context)}
           ,{<<"Preview">>, 'true'}
           | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
          ]),
    {API, _} = lists:foldl(fun preview_fold/2
                           ,{Preview, cb_context:doc(Context)}
                           ,wapi_notifications:headers(Id)
                          ),

    case wh_amqp_worker:call(API
                             ,publish_fun(Id)
                             ,fun wapi_notifications:notify_update_v/1
                            )
    of
        {'ok', Resp} ->
            lager:debug("sent API command to preview ~s: ~p: ~p", [Id, API]),
            handle_preview_response(Context, Resp);
        {'error', _E} ->
            lager:debug("failed to publish preview for ~s: ~p", [Id, _E]),
            crossbar_util:response('error', <<"Failed to process notification preview">>, Context)
    end.

-spec handle_preview_response(cb_context:context(), wh_json:object()) -> cb_context:context().
handle_preview_response(Context, Resp) ->
    case wh_json:get_value(<<"Status">>, Resp) of
        <<"failed">> ->
            lager:debug("failed notificaiton preview"),
            crossbar_util:response_invalid_data(
              wh_json:normalize(wh_api:remove_defaults(Resp))
              ,Context
             );
        _Status ->
            lager:debug("notification preview status :~s", [_Status]),
            crossbar_util:response_202(<<"Notification processing">>, Context)
    end.

-spec publish_fun(ne_binary()) -> fun((api_terms()) -> 'ok').
publish_fun(<<"voicemail">>) ->
    fun wapi_notifications:publish_voicemail/1;
publish_fun(<<"voicemail_full">>) ->
    fun wapi_notifications:publish_voicemail_full/1.

-spec preview_fold(ne_binary(), {wh_proplist(), wh_json:object()}) ->
                          {wh_proplist(), wh_json:object()}.
preview_fold(Header, {Props, ReqData}) ->
    case wh_json:get_first_defined([Header, wh_json:normalize_key(Header)], ReqData) of
        'undefined' -> {props:insert_value(Header, Header, Props), ReqData};
        V -> {props:set_value(Header, V, Props), ReqData}
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% If the HTTP verb is DELETE, execute the actual action, usually a db delete
%% @end
%%--------------------------------------------------------------------
-spec delete(cb_context:context(), path_token()) -> cb_context:context().
delete(Context, Id) ->
    ContentTypes = media_values(cb_context:req_header(Context, <<"content-type">>)),
    maybe_delete(Context, Id, ContentTypes).

-spec maybe_delete(cb_context:context(), path_token(), media_values()) ->
                          cb_context:context().
maybe_delete(Context, Id, [{{<<"application">>, <<"json">>, _},_,_}]) ->
    delete_doc(Context, Id);
maybe_delete(Context, Id, [{{<<"application">>, <<"x-json">>, _},_,_}]) ->
    delete_doc(Context, Id);
maybe_delete(Context, Id, [{{Type, SubType, _},_,_}]) ->
    maybe_delete_template(Context, Id, <<Type/binary, "/", SubType/binary>>);
maybe_delete(Context, Id, []) ->
    lager:debug("no content-type headers, using json"),
    delete_doc(Context, Id).

-spec delete_doc(cb_context:context(), ne_binary()) -> cb_context:context().
delete_doc(Context, _Id) ->
    Context1 = crossbar_doc:delete(Context),
    case cb_context:resp_status(Context1) of
        'success' -> leak_doc_id(Context1);
        _Status -> Context1
    end.

-spec maybe_delete_template(cb_context:context(), ne_binary(), ne_binary()) ->
                                   cb_context:context().
-spec maybe_delete_template(cb_context:context(), ne_binary(), ne_binary(), wh_json:object()) ->
                                   cb_context:context().
maybe_delete_template(Context, Id, ContentType) ->
    maybe_delete_template(Context, Id, ContentType, cb_context:doc(Context)).

maybe_delete_template(Context, Id, ContentType, TemplateJObj) ->
    AttachmentName = attachment_name_by_media_type(ContentType),
    case wh_doc:attachment(TemplateJObj, AttachmentName) of
        'undefined' ->
            lager:debug("failed to find attachment ~s", [AttachmentName]),
            cb_context:add_system_error('bad_identifier', [{'details', ContentType}],  Context);
        _Attachment ->
            lager:debug("attempting to delete attachment ~s", [AttachmentName]),
            crossbar_doc:delete_attachment(db_id(Id), AttachmentName, Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Create a new instance with the data provided, if it is valid
%% @end
%%--------------------------------------------------------------------
-spec create(cb_context:context()) -> cb_context:context().
create(Context) ->
    OnSuccess = fun(C) -> on_successful_validation('undefined', C) end,
    cb_context:validate_request_data(<<"notifications">>, Context, OnSuccess).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load an instance from the database
%% @end
%%--------------------------------------------------------------------

-type media_value() :: {{ne_binary(), ne_binary(), list()}, non_neg_integer(),list()}.
-type media_values() :: [media_value(),...] | [].

-spec accept_values(cb_context:context()) -> media_values().
accept_values(Context) ->
    AcceptValue = cb_context:req_header(Context, <<"accept">>),
    Tunneled = cb_context:req_value(Context, <<"accept">>),

    media_values(AcceptValue, Tunneled).

-spec media_values(api_binary()) -> media_values().
-spec media_values(api_binary(), api_binary()) -> media_values().
media_values(Media) ->
    media_values(Media, 'undefined').

media_values('undefined', 'undefined') ->
    lager:debug("no accept headers, assuming JSON"),
    [{{<<"application">>, <<"json">>, []},1000,[]}];
media_values(AcceptValue, 'undefined') ->
    case cowboy_http:nonempty_list(AcceptValue, fun cowboy_http:media_range/2) of
        {'error', 'badarg'} -> media_values('undefined', 'undefined');
        AcceptValues -> lists:reverse(lists:keysort(2, AcceptValues))
    end;
media_values(AcceptValue, Tunneled) ->
    case cowboy_http:nonempty_list(Tunneled, fun cowboy_http:media_range/2) of
        {'error', 'badarg'} -> media_values(AcceptValue, 'undefined');
        TunneledValues ->
            lager:debug("using tunneled accept value ~s", [Tunneled]),
            lists:reverse(lists:keysort(2, TunneledValues))
    end.

-spec acceptable_content_types(cb_context:context()) -> wh_proplist().
acceptable_content_types(Context) ->
    props:get_value('to_binary', cb_context:content_types_provided(Context), []).

-spec maybe_read(cb_context:context(), ne_binary()) -> cb_context:context().
-spec maybe_read(cb_context:context(), ne_binary(), wh_proplist(), media_values()) -> cb_context:context().
maybe_read(Context, Id) ->
    Acceptable = acceptable_content_types(Context),
    maybe_read(Context, Id, Acceptable, accept_values(Context)).

maybe_read(Context, Id, _Acceptable, [{{<<"application">>, <<"json">>, _},_,_}|_Accepts]) ->
    read(Context, Id);
maybe_read(Context, Id, _Acceptable, [{{<<"application">>, <<"x-json">>, _},_,_}|_Accepts]) ->
    read(Context, Id);
maybe_read(Context, Id, _Acceptable, [{{<<"*">>, <<"*">>, _},_,_}|_Accepts]) ->
    lager:debug("catch-all accept header, using json"),
    read(Context, Id);
maybe_read(Context, Id, Acceptable, [{{Type, SubType, _},_,_}|Accepts]) ->
    case is_acceptable_accept(Acceptable, Type, SubType) of
        'false' ->
            lager:debug("unknown accept header: ~s/~s", [Type, SubType]),
            maybe_read(Context, Id, Acceptable, Accepts);
        'true' ->
            lager:debug("accept header: ~s/~s", [Type, SubType]),
            maybe_read_template(read(Context, Id), Id, <<Type/binary, "/", SubType/binary>>)
    end;
maybe_read(Context, Id, _Acceptable, []) ->
    lager:debug("no accept headers, using json"),
    read(Context, Id).

-spec is_acceptable_accept(wh_proplist(), ne_binary(), ne_binary()) -> boolean().
is_acceptable_accept(Acceptable, Type, SubType) ->
    lists:any(fun({T, S}) ->
                      T =:= Type andalso S =:= SubType
              end, Acceptable).

-type load_from() :: 'system' | 'account'.

-spec read(cb_context:context(), ne_binary()) -> cb_context:context().
-spec read(cb_context:context(), ne_binary(), load_from()) -> cb_context:context().
read(Context, Id) ->
    read(Context, Id, 'system').

read(Context, Id, LoadFrom) ->
    Context1 =
        case cb_context:account_db(Context) of
            'undefined' when LoadFrom =:= 'system' -> read_system(Context, Id);
            _AccountDb -> read_account(Context, Id, LoadFrom)
        end,
    case cb_context:resp_status(Context1) of
        'success' -> read_success(Context1);
        _Status -> Context1
    end.

-spec read_system(cb_context:context(), ne_binary()) -> cb_context:context().
read_system(Context, Id) ->
    {'ok', MasterAccountDb} = whapps_util:get_master_account_db(),
    crossbar_doc:load(Id, cb_context:set_account_db(Context, MasterAccountDb)).

-spec read_account(cb_context:context(), ne_binary(), load_from()) -> cb_context:context().
read_account(Context, Id, LoadFrom) ->
    Context1 = crossbar_doc:load(Id, Context),
    case {cb_context:resp_error_code(Context1)
          ,cb_context:resp_status(Context1)
         }
    of
        {404, 'error'} when LoadFrom =:= 'system' -> read_system(Context, Id);
        {_Code, 'success'} ->
            lager:debug("loaded from account"),
            cb_context:set_resp_data(Context1
                                     ,note_account_override(cb_context:resp_data(Context1))
                                    );
        {_Code, _Status} -> Context1
    end.

-spec note_account_override(wh_json:object()) -> wh_json:object().
note_account_override(JObj) ->
    wh_json:set_value(<<"account_overridden">>, 'true', JObj).

-spec read_success(cb_context:context()) -> cb_context:context().
read_success(Context) ->
    cb_context:setters(Context
                       ,[fun leak_attachments/1
                         ,fun leak_doc_id/1
                        ]).

-spec maybe_read_template(cb_context:context(), ne_binary(), ne_binary()) -> cb_context:context().
maybe_read_template(Context, _Id, <<"application/json">>) -> Context;
maybe_read_template(Context, _Id, <<"application/x-json">>) -> Context;
maybe_read_template(Context, Id, Accept) ->
    case cb_context:resp_status(Context) of
        'success' -> read_template(Context, Id, Accept);
        _Status -> Context
    end.

-spec read_template(cb_context:context(), ne_binary(), ne_binary()) -> cb_context:context().
read_template(Context, Id, Accept) ->
    Doc = cb_context:fetch(Context, 'db_doc'),
    AttachmentName = attachment_name_by_media_type(Accept),
    case wh_json:get_value([<<"_attachments">>, AttachmentName], Doc) of
        'undefined' ->
            lager:debug("failed to find attachment ~s in ~s", [AttachmentName, Id]),
            crossbar_util:response_faulty_request(Context);
        Meta ->
            lager:debug("found attachment ~s in ~s", [AttachmentName, Id]),

            cb_context:add_resp_headers(
              crossbar_doc:load_attachment(Id, AttachmentName, Context)
              ,[{<<"Content-Disposition">>, [<<"attachment; filename=">>, resp_id(Id), $., cb_modules_util:content_type_to_extension(Accept)]}
                ,{<<"Content-Type">>, wh_json:get_value(<<"content_type">>, Meta)}
                ,{<<"Content-Length">>, wh_json:get_value(<<"length">>, Meta)}
               ])
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Update an existing menu document with the data provided, if it is
%% valid
%% @end
%%--------------------------------------------------------------------
-spec maybe_update(cb_context:context(), ne_binary()) -> cb_context:context().
maybe_update(Context, Id) ->
    case cb_context:req_files(Context) of
        [] -> update(Context, Id);
        [{_FileName, FileJObj}] ->
            lager:debug("recv template upload of ~s: ~p", [_FileName, FileJObj]),
            read(Context, Id)
    end.

-spec update(cb_context:context(), ne_binary()) -> cb_context:context().
update(Context, Id) ->
    OnSuccess = fun(C) -> on_successful_validation(Id, C) end,
    cb_context:validate_request_data(<<"notifications">>, Context, OnSuccess).

-spec update_template(cb_context:context(), path_token(), wh_json:object()) ->
                             cb_context:context().
update_template(Context, Id, FileJObj) ->
    Contents = wh_json:get_value(<<"contents">>, FileJObj),
    CT = wh_json:get_value([<<"headers">>, <<"content_type">>], FileJObj),
    lager:debug("file content type for ~s: ~s", [Id, CT]),
    Opts = [{'headers', [{'content_type', wh_util:to_list(CT)}]}],

    Context1 =
        case cb_context:account_db(Context) of
            'undefined' ->
                {'ok', MasterAccountDb} = whapps_util:get_master_account_db(),
                cb_context:set_account_db(Context, MasterAccountDb);
            _AccountDb -> Context
        end,

    AttachmentName = attachment_name_by_content_type(CT),

    crossbar_doc:save_attachment(
      Id
      ,AttachmentName
      ,Contents
      ,Context1
      ,Opts
     ).

-spec attachment_name_by_content_type(ne_binary()) -> ne_binary().
attachment_name_by_content_type(CT) ->
    <<"template.", (cow_qs:urlencode(CT))/binary>>.

-spec attachment_name_by_media_type(ne_binary()) -> ne_binary().
attachment_name_by_media_type(CT) ->
    <<"template.", CT/binary>>.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to load a summarized listing of all instances of this
%% resource.
%% @end
%%--------------------------------------------------------------------
-spec summary(cb_context:context()) -> cb_context:context().
summary(Context) ->
    case cb_context:account_db(Context) of
        'undefined' -> summary_available(Context);
        _AccountDb -> summary_account(Context)
    end.

-spec summary_available(cb_context:context()) -> cb_context:context().
summary_available(Context) ->
    case fetch_available() of
        {'ok', Available} ->
            crossbar_doc:handle_json_success(Available, Context);
        {'error', 'not_found'} ->
            fetch_summary_available(Context)
    end.

-spec fetch_summary_available(cb_context:context()) -> cb_context:context().
fetch_summary_available(Context) ->
    {'ok', MasterAccountDb} = whapps_util:get_master_account_db(),
    Context1 =
        crossbar_doc:load_view(?CB_LIST
                               ,[]
                               ,cb_context:set_account_db(Context, MasterAccountDb)
                               ,fun normalize_available/2
                              ),
    cache_available(Context1),
    Context1.

-spec cache_available(cb_context:context()) -> 'ok'.
cache_available(Context) ->
    wh_cache:store_local(?CROSSBAR_CACHE
                         ,{?MODULE, 'available'}
                         ,cb_context:doc(Context)
                         ,[{'origin', [{'db', cb_context:account_db(Context), ?PVT_TYPE}]}]
                        ).

-spec fetch_available() -> {'ok', wh_json:objects()} |
                           {'error', 'not_found'}.
fetch_available() ->
    wh_cache:fetch_local(?CROSSBAR_CACHE, {?MODULE, 'available'}).

-spec summary_account(cb_context:context()) -> cb_context:context().
-spec summary_account(cb_context:context(), wh_json:objects()) -> cb_context:context().
summary_account(Context) ->
    Context1 =
        crossbar_doc:load_view(?CB_LIST
                               ,[]
                               ,Context
                               ,fun normalize_available/2
                              ),
    summary_account(Context1, cb_context:doc(Context1)).

summary_account(Context, AccountAvailable) ->
    Context1 = summary_available(Context),
    Available = cb_context:doc(Context1),

    crossbar_doc:handle_json_success(
      merge_available(AccountAvailable, Available)
      ,Context
     ).

-spec merge_available(wh_json:objects(), wh_json:objects()) ->
                             wh_json:objects().
merge_available([], Available) ->
    lager:debug("account has not overridden any, using system notifications"),
    Available;
merge_available(AccountAvailable, Available) ->
    lists:foldl(fun merge_fold/2, Available, AccountAvailable).

-spec merge_fold(wh_json:object(), wh_json:objects()) -> wh_json:objects().
merge_fold(Overridden, Acc) ->
    Id = wh_json:get_value(<<"id">>, Overridden),
    [note_account_override(Overridden)
     | [JObj || JObj <- Acc, wh_json:get_value(<<"id">>, JObj) =/= Id]
    ].

-spec normalize_available(wh_json:object(), wh_json:objects()) -> wh_json:objects().
normalize_available(JObj, Acc) ->
    [wh_json:get_value(<<"value">>, JObj) | Acc].

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------

-spec master_notification_doc(ne_binary()) -> {'ok', wh_json:object()} |
                                              {'error', _}.
master_notification_doc(DocId) ->
    {'ok', MasterAccountDb} = whapps_util:get_master_account_db(),
    couch_mgr:open_cache_doc(MasterAccountDb, DocId).

-spec on_successful_validation(api_binary(), cb_context:context()) -> cb_context:context().
on_successful_validation('undefined', Context) ->
    ReqTemplate = clean_req_doc(cb_context:doc(Context)),

    DocId = db_id(wh_json:get_value(<<"id">>, ReqTemplate)),

    case master_notification_doc(DocId) of
        {'ok', _JObj} ->
            Doc = wh_json:set_values([{<<"pvt_type">>, ?PVT_TYPE}
                                      ,{<<"_id">>, DocId}
                                     ], ReqTemplate),
            cb_context:set_doc(Context, Doc);
        {'error', 'not_found'} ->
            handle_missing_master_notification(Context, DocId, ReqTemplate);
        {'error', _E} ->
            lager:debug("error fetching ~s from master account: ~p", [DocId, _E]),
            crossbar_util:response_db_fatal(Context)
    end;
on_successful_validation(Id, Context) ->
    Context1 = crossbar_doc:load_merge(Id, Context),
    case cb_context:resp_error_code(Context1) of
        404 ->
            handle_missing_account_notification(Context1, Id);
        _Code ->
            Context1
    end.

-spec handle_missing_account_notification(cb_context:context(), ne_binary()) -> cb_context:context().
handle_missing_account_notification(Context, Id) ->
    ReqTemplate = clean_req_doc(cb_context:doc(Context)),

    case master_notification_doc(Id) of
        {'ok', JObj} ->
            lager:debug("account version of ~s missing but master version found, using that", [Id]),
            crossbar_doc:merge(ReqTemplate, JObj, Context);
        {'error', _E} ->
            lager:debug("failed to load master account notification ~s: ~p", [Id, _E]),
            Context
    end.

-spec handle_missing_master_notification(cb_context:context(), ne_binary(), wh_json:object()) ->
                                                cb_context:context().
handle_missing_master_notification(Context, DocId, ReqTemplate) ->
    {'ok', MasterAccountId} = whapps_util:get_master_account_id(),
    case cb_context:account_id(Context) of
        'undefined' ->
            lager:debug("creating master notification for ~s", [DocId]),
            create_new_notification(Context, DocId, ReqTemplate, MasterAccountId);
        MasterAccountId ->
            lager:debug("creating master notification for ~s", [DocId]),
            create_new_notification(Context, DocId, ReqTemplate, MasterAccountId);
        _AccountId ->
            lager:debug("doc ~s does not exist in the master account, not letting ~s create it"
                        ,[DocId, _AccountId]
                       ),
            crossbar_util:response_bad_identifier(resp_id(DocId), Context)
    end.

-spec create_new_notification(cb_context:context(), ne_binary(), wh_json:object(), ne_binary()) ->
                                     cb_context:context().
create_new_notification(Context, DocId, ReqTemplate, AccountId) ->
    lager:debug("this will create a new template in the master account"),
    Doc = wh_json:set_values([{<<"pvt_type">>, ?PVT_TYPE}
                              ,{<<"_id">>, DocId}
                             ], ReqTemplate),
    cb_context:setters(Context
                       ,[{fun cb_context:set_doc/2, Doc}
                         ,{fun cb_context:set_account_db/2, wh_util:format_account_id(AccountId, 'encoded')}
                         ,{fun cb_context:set_account_id/2, AccountId}
                        ]).

-spec clean_req_doc(wh_json:object()) -> wh_json:object().
clean_req_doc(Doc) ->
    wh_json:delete_keys([?MACROS], Doc).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec db_id(ne_binary()) -> ne_binary().
db_id(<<"notification.", _/binary>> = Id) -> Id;
db_id(Id) -> <<"notification.", Id/binary>>.

-spec resp_id(ne_binary()) -> ne_binary().
resp_id(<<"notification.", Id/binary>>) -> Id;
resp_id(Id) -> Id.

-spec leak_doc_id(cb_context:context()) -> cb_context:context().
leak_doc_id(Context) ->
    RespData = cb_context:resp_data(Context),
    DocId = wh_json:get_first_defined([<<"_id">>, <<"id">>], RespData),
    cb_context:set_resp_data(Context, wh_json:set_value(<<"id">>, resp_id(DocId), RespData)).

-spec leak_attachments(cb_context:context()) -> cb_context:context().
leak_attachments(Context) ->
    Attachments = wh_json:get_value(<<"_attachments">>, cb_context:fetch(Context, 'db_doc'), wh_json:new()),
    Templates = wh_json:foldl(fun leak_attachments_fold/3, wh_json:new(), Attachments),
    cb_context:set_resp_data(Context
                             ,wh_json:set_value(<<"templates">>, Templates, cb_context:resp_data(Context))
                            ).

-spec leak_attachments_fold(wh_json:key(), wh_json:json_term(), wh_json:object()) -> wh_json:object().
leak_attachments_fold(_Attachment, Props, Acc) ->
    wh_json:set_value(wh_json:get_value(<<"content_type">>, Props)
                      ,wh_json:from_list([{<<"length">>, wh_json:get_integer_value(<<"length">>, Props)}])
                      ,Acc
                     ).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

merge_available_test() ->
    Available = wh_json:decode(<<"[{\"id\":\"o1\",\"k1\":\"v1\"},{\"id\":\"o2\",\"k2\":\"v2\"},{\"id\":\"o3\",\"k3\":\"v3\"}]">>),
    AccountAvailable = wh_json:decode(<<"[{\"id\":\"o1\",\"k1\":\"a1\"},{\"id\":\"o2\",\"k2\":\"a2\"}]">>),

    Merged = merge_available(AccountAvailable, Available),

    ?assertEqual(<<"a1">>, wh_json:get_value([2,<<"k1">>], Merged)),
    ?assertEqual(<<"a2">>, wh_json:get_value([1,<<"k2">>], Merged)),
    ?assertEqual(<<"v3">>, wh_json:get_value([3,<<"k3">>], Merged)).

-endif.
