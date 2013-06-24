-module(ecdrs).

crossbar_listing({Doc}) ->
    ToInt = fun(X) when is_binary(X) -> list_to_integer(binary_to_list(X));
               (X) when is_integer(X) -> X;
               (X) when is_float(X) -> round(X)
            end,
    ToFloat = fun(X) when is_binary(X) -> list_to_float(binary_to_list(X));
                 (X) when is_integer(X) -> X*1.0;
                 (X) when is_float(X) -> X
              end,

    case proplists:get_value(<<"pvt_deleted">>, Doc) =:= true
        orelse proplists:get_value(<<"pvt_type">>, Doc) =/= <<"cdr">>
    of
        true -> ok;
        false ->
            case ToInt(proplists:get_value(<<"billing_seconds">>, Doc, 0)) of
                Secs when Secs < 1 -> ok;
                Secs when Secs >= 1 ->
                    {CCVs} = proplists:get_value(<<"custom_channel_vars">>, Doc, {[]}),
                    R = round(ToFloat(proplists:get_value(<<"rate">>, CCVs, 0.0)) * 10000),
                    RInc = case ToInt(proplists:get_value(<<"increment">>, CCVs, 60)) of N when N < 1 -> 60; N -> N end,
                    RMin = ToInt(proplists:get_value(<<"rate_minimum">>, CCVs, 0)),
                    Sur = ToFloat(proplists:get_value(<<"surcharge">>, CCVs, 0.0)),

                    Cost = case Secs =< RMin of
                               true -> Sur + ((RMin / 60) * R);
                               false ->
                                   Sur + ((RMin/60)*R) + (round((Secs-RMin)/RInc)*((RInc/60)*R))
                           end,

                    Emit(proplists:get_value(<<"pvt_created">>, Doc)
                         ,{[{<<"id">>, proplists:get_value(<<"_id">>, Doc)}
                            ,{<<"caller_id_name">>, proplists:get_value(<<"caller_id_name">>, Doc)}
                            ,{<<"caller_id_number">>, proplists:get_value(<<"caller_id_number">>, Doc)}
                            ,{<<"callee_id_name">>, proplists:get_value(<<"callee_id_name">>, Doc)}
                            ,{<<"callee_id_number">>, proplists:get_value(<<"callee_id_number">>, Doc)}
                            ,{<<"duration_seconds">>, proplists:get_value(<<"duration_seconds">>, Doc)}
                            ,{<<"billing_seconds">>, proplists:get_value(<<"billing_seconds">>, Doc)}
                            ,{<<"timestamp">>, proplists:get_value(<<"timestamp">>, Doc)}
                            ,{<<"hangup_cause">>, proplists:get_value(<<"hangup_cause">>, Doc)}
                            ,{<<"other_leg_call_id">>, proplists:get_value(<<"other_leg_call_id">>, Doc)}
                            ,{<<"owner_id">>, proplists:get_value(<<"owner_id">>, CCVs)}
                            ,{<<"to">>, proplists:get_value(<<"to_uri">>, Doc)}
                            ,{<<"from">>, proplists:get_value(<<"from_uri">>, Doc)}
                            ,{<<"inception">>, proplists:get_value(<<"inception">>, CCVs)}
                            ,{<<"cost">>,Cost}
                           ]})
            end
    end.
