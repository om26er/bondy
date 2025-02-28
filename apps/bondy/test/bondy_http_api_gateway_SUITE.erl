%% =============================================================================
%%  bondy_http_api_gateway_SUITE.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

-module(bondy_http_api_gateway_SUITE).
-include_lib("common_test/include/ct.hrl").
-compile([nowarn_export_all, export_all]).


all() ->
    bondy_ct:all().

groups() ->
    [{main, [parallel], bondy_ct:tests(?MODULE)}].

simple_1_test(_) ->
    Spec = #{
        <<"id">> => <<"com.myapi">>,
        <<"name">> => <<"com.myapi">>,
        <<"host">> => <<"[www.]myapi.com">>,
        <<"realm_uri">> => <<"com.myapi">>,
        <<"variables">> => #{
            <<"foo">> => 100,
            <<"schemes">> => [<<"http">>],
            <<"oauth2">> => #{
                <<"type">> => <<"oauth2">>,
                <<"flow">> => <<"resource_owner_password_credentials">>,
                <<"token_path">> => <<"/auth/token">>,
                <<"revoke_token_path">> => <<"/auth/revoke_token">>,
                <<"schemes">> => <<"{{variables.schemes}}">>
            }
        },
        <<"defaults">> => #{
            <<"timeout">> => 15000,
            <<"security">> => <<"{{variables.oauth2}}">>,
            <<"schemes">> => <<"{{variables.schemes}}">>
        },
        <<"versions">> =>  #{
            <<"1.0.0">> => #{
                <<"base_path">> => <<"/v1.0">>,
                <<"variables">> => #{
                    <<"foo">> => 200
                },
                <<"defaults">> => #{
                    <<"timeout">> => 20000
                },
                <<"paths">> => #{
                    <<"/things">> => #{
                        <<"variables">> => #{
                            <<"foo">> => 300
                        },
                        <<"defaults">> => #{
                            <<"timeout">> => 30000
                        },
                        <<"get">> => #{
                            <<"action">> => #{
                                <<"type">> => <<"wamp_call">>,
                                <<"procedure">> => <<"com.magenta.things.list">>,
                                <<"options">> => #{},
                                <<"args">> => [
                                    <<"{{request.query_params}}">>
                                ],
                                <<"kwargs">> => #{}
                            },
                            <<"response">> => #{
                                <<"on_error">> => #{

                                },
                                <<"on_result">> => #{
                                  <<"body">> => <<"{{action.result}}">>
                                }
                            }
                        }
                    },
                    <<"/agents">> => #{
                        <<"security">> => #{},
                        <<"get">> => #{
                            <<"action">> => #{
                                <<"type">> => <<"wamp_call">>,
                                <<"procedure">> => <<"com.myapi.foo">>,
                                <<"options">> => #{},
                                <<"args">> => [<<"{{variables.foo}}">>],
                                <<"kwargs">> => #{}
                            },
                            <<"response">> => #{
                                <<"on_error">> => #{

                                },
                                <<"on_result">> => #{

                                }
                            }
                        }
                    }
                }
            }
        }
    },
    bondy_http_gateway_api_spec_parser:parse(Spec).


%% png() ->
%%     <<137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,1,194,
%%  0,0,1,194,1,0,0,0,0,84,99,244,232,0,0,2,149,73,68,65,84,
%%  120,156,237,218,205,141,166,48,12,128,97,75,20,64,73,
%%  180,78,73,41,0,201,59,241,95,2,4,105,53,199,209,155,195,
%%  44,240,229,201,201,178,157,100,69,127,57,78,65,34,145,
%%  72,36,18,137,252,67,82,98,108,42,135,127,238,79,45,190,
%%  170,182,237,231,99,190,230,20,36,114,150,246,210,39,136,
%%  236,182,144,61,93,125,214,213,167,244,39,227,53,25,137,
%%  124,200,30,90,71,6,153,158,251,125,106,219,226,207,28,
%%  160,72,228,82,90,184,217,132,31,174,177,80,69,31,18,249,
%%  31,82,50,240,60,250,78,95,227,146,200,111,72,228,151,
%%  180,127,178,10,122,215,228,5,176,69,79,21,237,84,77,70,
%%  34,63,187,241,246,249,103,217,141,35,145,250,28,22,100,
%%  45,19,213,20,135,247,129,68,62,101,100,171,81,246,134,
%%  204,215,222,98,213,15,72,228,162,10,122,195,212,215,136,
%%  70,60,27,43,171,140,167,140,53,144,200,133,204,125,92,
%%  165,172,172,120,227,124,160,218,116,36,114,33,179,213,
%%  246,192,179,72,243,56,180,132,230,107,220,6,18,185,146,
%%  86,241,44,232,50,131,101,101,148,88,35,14,154,144,200,
%%  167,84,79,79,90,23,36,18,21,207,130,49,126,240,215,11,
%%  137,92,201,56,152,244,249,113,88,25,145,230,103,1,21,
%%  155,185,16,18,121,151,49,33,47,106,125,130,212,26,145,
%%  188,110,91,61,36,242,41,227,183,220,252,235,196,179,187,
%%  170,115,74,36,242,189,47,155,75,92,236,237,44,115,101,1,
%%  140,245,61,201,41,18,185,146,213,68,213,83,221,180,141,
%%  70,220,175,74,14,36,242,45,227,30,100,28,100,103,184,29,
%%  245,237,152,146,28,18,249,170,130,241,255,66,70,124,141,
%%  249,61,105,237,241,228,231,3,138,68,46,164,229,40,15,
%%  188,186,37,209,40,143,89,20,151,221,56,18,153,82,100,
%%  238,198,125,161,106,157,234,156,114,145,193,144,72,155,
%%  112,20,138,254,73,178,236,85,115,62,154,40,69,34,95,50,
%%  171,96,78,29,107,244,176,180,249,99,33,36,242,75,206,5,
%%  208,247,113,146,141,85,171,42,152,11,33,145,119,57,109,
%%  215,250,240,32,243,155,182,58,41,176,16,148,103,39,133,
%%  68,206,157,212,185,215,249,192,232,154,218,150,167,147,
%%  126,211,134,68,46,101,196,87,238,251,167,39,145,145,193,
%%  242,9,137,124,203,49,230,112,211,177,218,86,25,76,145,
%%  200,149,204,48,219,178,47,159,246,118,91,214,190,12,60,
%%  36,114,37,237,165,122,240,231,147,14,212,228,190,163,67,
%%  34,171,27,143,18,23,159,247,171,110,68,108,171,87,1,154,
%%  169,13,137,252,146,50,221,180,89,164,53,153,47,77,226,
%%  200,9,137,252,150,153,178,44,210,226,84,96,74,99,239,78,
%%  10,137,204,168,82,157,107,95,222,141,248,175,113,108,
%%  153,129,167,72,228,91,198,8,25,241,229,121,235,146,49,
%%  60,44,15,36,242,37,127,49,144,72,36,18,137,68,34,255,
%%  136,252,7,82,229,116,60,181,103,147,118,0,0,0,0,73,69,
%%  78,68,174,66,96,130>>.