defmodule Pixir.Provider.OpenResponsesSchema.Generated do
  @moduledoc """
  Generated, pinned Open Responses HTTP/SSE schema subset.

  Do not edit this module by hand. Regenerate it with
  `uv run python bin/generate-open-responses-schema`. The runtime performs no schema
  parsing, filesystem access, reference resolution outside this module, or network I/O.
  """

  @event_roots %{
    "error" => "ErrorStreamingEvent",
    "response.completed" => "ResponseCompletedStreamingEvent",
    "response.content_part.added" => "ResponseContentPartAddedStreamingEvent",
    "response.content_part.done" => "ResponseContentPartDoneStreamingEvent",
    "response.created" => "ResponseCreatedStreamingEvent",
    "response.failed" => "ResponseFailedStreamingEvent",
    "response.function_call_arguments.delta" =>
      "ResponseFunctionCallArgumentsDeltaStreamingEvent",
    "response.function_call_arguments.done" => "ResponseFunctionCallArgumentsDoneStreamingEvent",
    "response.in_progress" => "ResponseInProgressStreamingEvent",
    "response.incomplete" => "ResponseIncompleteStreamingEvent",
    "response.output_item.added" => "ResponseOutputItemAddedStreamingEvent",
    "response.output_item.done" => "ResponseOutputItemDoneStreamingEvent",
    "response.output_text.annotation.added" => "ResponseOutputTextAnnotationAddedStreamingEvent",
    "response.output_text.delta" => "ResponseOutputTextDeltaStreamingEvent",
    "response.output_text.done" => "ResponseOutputTextDoneStreamingEvent",
    "response.queued" => "ResponseQueuedStreamingEvent",
    "response.reasoning.delta" => "ResponseReasoningDeltaStreamingEvent",
    "response.reasoning.done" => "ResponseReasoningDoneStreamingEvent",
    "response.reasoning_summary_part.added" => "ResponseReasoningSummaryPartAddedStreamingEvent",
    "response.reasoning_summary_part.done" => "ResponseReasoningSummaryPartDoneStreamingEvent",
    "response.reasoning_summary_text.delta" => "ResponseReasoningSummaryDeltaStreamingEvent",
    "response.reasoning_summary_text.done" => "ResponseReasoningSummaryDoneStreamingEvent",
    "response.refusal.delta" => "ResponseRefusalDeltaStreamingEvent",
    "response.refusal.done" => "ResponseRefusalDoneStreamingEvent"
  }
  @schemas %{
    "AllowedToolChoice" => %{
      "properties" => %{
        "mode" => %{
          "$ref" => "ToolChoiceValueEnum"
        },
        "tools" => %{
          "items" => %{
            "oneOf" => [
              %{
                "$ref" => "FunctionToolChoice"
              }
            ]
          },
          "type" => "array"
        },
        "type" => %{
          "enum" => [
            "allowed_tools"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "tools",
        "mode"
      ],
      "type" => "object"
    },
    "Annotation" => %{
      "oneOf" => [
        %{
          "$ref" => "UrlCitationBody"
        }
      ],
      "x-pixir-discriminator" => %{
        "index" => %{
          "url_citation" => 0
        },
        "property" => "type"
      }
    },
    "CompactionBody" => %{
      "properties" => %{
        "created_by" => %{
          "type" => "string"
        },
        "encrypted_content" => %{
          "type" => "string"
        },
        "id" => %{
          "type" => "string"
        },
        "type" => %{
          "enum" => [
            "compaction"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "id",
        "encrypted_content"
      ],
      "type" => "object"
    },
    "Error" => %{
      "properties" => %{
        "code" => %{
          "type" => "string"
        },
        "message" => %{
          "type" => "string"
        }
      },
      "required" => [
        "code",
        "message"
      ],
      "type" => "object"
    },
    "ErrorPayload" => %{
      "properties" => %{
        "code" => %{
          "anyOf" => [
            %{
              "type" => "string"
            },
            %{
              "type" => "null"
            }
          ]
        },
        "headers" => %{
          "additionalProperties" => %{
            "type" => "string"
          },
          "type" => "object"
        },
        "message" => %{
          "type" => "string"
        },
        "param" => %{
          "anyOf" => [
            %{
              "type" => "string"
            },
            %{
              "type" => "null"
            }
          ]
        },
        "type" => %{
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "code",
        "message",
        "param"
      ],
      "type" => "object"
    },
    "ErrorStreamingEvent" => %{
      "properties" => %{
        "error" => %{
          "allOf" => [
            %{
              "$ref" => "ErrorPayload"
            },
            %{}
          ]
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "error"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "error"
      ],
      "type" => "object"
    },
    "FunctionCall" => %{
      "properties" => %{
        "arguments" => %{
          "type" => "string"
        },
        "call_id" => %{
          "type" => "string"
        },
        "id" => %{
          "type" => "string"
        },
        "name" => %{
          "type" => "string"
        },
        "status" => %{
          "allOf" => [
            %{
              "$ref" => "FunctionCallStatus"
            },
            %{}
          ]
        },
        "type" => %{
          "enum" => [
            "function_call"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "id",
        "call_id",
        "name",
        "arguments",
        "status"
      ],
      "type" => "object"
    },
    "FunctionCallOutput" => %{
      "properties" => %{
        "call_id" => %{
          "type" => "string"
        },
        "id" => %{
          "type" => "string"
        },
        "output" => %{
          "oneOf" => [
            %{
              "type" => "string"
            },
            %{
              "items" => %{
                "oneOf" => [
                  %{
                    "$ref" => "InputTextContent"
                  },
                  %{
                    "$ref" => "InputImageContent"
                  },
                  %{
                    "$ref" => "InputFileContent"
                  }
                ],
                "x-pixir-discriminator" => %{
                  "index" => %{
                    "input_file" => 2,
                    "input_image" => 1,
                    "input_text" => 0
                  },
                  "property" => "type"
                }
              },
              "type" => "array"
            }
          ]
        },
        "status" => %{
          "allOf" => [
            %{
              "$ref" => "FunctionCallOutputStatusEnum"
            },
            %{}
          ]
        },
        "type" => %{
          "enum" => [
            "function_call_output"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "id",
        "call_id",
        "output",
        "status"
      ],
      "type" => "object"
    },
    "FunctionCallOutputStatusEnum" => %{
      "enum" => [
        "in_progress",
        "completed",
        "incomplete"
      ],
      "type" => "string"
    },
    "FunctionCallStatus" => %{
      "enum" => [
        "in_progress",
        "completed",
        "incomplete"
      ],
      "type" => "string"
    },
    "FunctionTool" => %{
      "properties" => %{
        "description" => %{
          "anyOf" => [
            %{
              "type" => "string"
            },
            %{
              "type" => "null"
            }
          ]
        },
        "name" => %{
          "type" => "string"
        },
        "parameters" => %{
          "anyOf" => [
            %{
              "additionalProperties" => %{},
              "type" => "object"
            },
            %{
              "type" => "null"
            }
          ]
        },
        "strict" => %{
          "anyOf" => [
            %{
              "type" => "boolean"
            },
            %{
              "type" => "null"
            }
          ]
        },
        "type" => %{
          "enum" => [
            "function"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "name",
        "description",
        "parameters",
        "strict"
      ],
      "type" => "object"
    },
    "FunctionToolChoice" => %{
      "properties" => %{
        "name" => %{
          "type" => "string"
        },
        "type" => %{
          "enum" => [
            "function"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type"
      ],
      "type" => "object"
    },
    "ImageDetail" => %{
      "enum" => [
        "low",
        "high",
        "auto"
      ],
      "type" => "string"
    },
    "IncompleteDetails" => %{
      "properties" => %{
        "reason" => %{
          "type" => "string"
        }
      },
      "required" => [
        "reason"
      ],
      "type" => "object"
    },
    "InputFileContent" => %{
      "properties" => %{
        "file_url" => %{
          "type" => "string"
        },
        "filename" => %{
          "type" => "string"
        },
        "type" => %{
          "enum" => [
            "input_file"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type"
      ],
      "type" => "object"
    },
    "InputImageContent" => %{
      "properties" => %{
        "detail" => %{
          "allOf" => [
            %{
              "$ref" => "ImageDetail"
            },
            %{}
          ]
        },
        "image_url" => %{
          "anyOf" => [
            %{
              "type" => "string"
            },
            %{
              "type" => "null"
            }
          ]
        },
        "type" => %{
          "enum" => [
            "input_image"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "image_url",
        "detail"
      ],
      "type" => "object"
    },
    "InputTextContent" => %{
      "properties" => %{
        "text" => %{
          "type" => "string"
        },
        "type" => %{
          "enum" => [
            "input_text"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "text"
      ],
      "type" => "object"
    },
    "InputTokensDetails" => %{
      "properties" => %{
        "cached_tokens" => %{
          "type" => "integer"
        }
      },
      "required" => [
        "cached_tokens"
      ],
      "type" => "object"
    },
    "InputVideoContent" => %{
      "properties" => %{
        "type" => %{
          "enum" => [
            "input_video"
          ],
          "type" => "string"
        },
        "video_url" => %{
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "video_url"
      ],
      "type" => "object"
    },
    "ItemField" => %{
      "oneOf" => [
        %{
          "$ref" => "Message"
        },
        %{
          "$ref" => "FunctionCall"
        },
        %{
          "$ref" => "FunctionCallOutput"
        },
        %{
          "$ref" => "ReasoningBody"
        },
        %{
          "$ref" => "CompactionBody"
        }
      ],
      "x-pixir-discriminator" => %{
        "index" => %{
          "compaction" => 4,
          "function_call" => 1,
          "function_call_output" => 2,
          "message" => 0,
          "reasoning" => 3
        },
        "property" => "type"
      }
    },
    "JsonObjectResponseFormat" => %{
      "properties" => %{
        "type" => %{
          "enum" => [
            "json_object"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type"
      ],
      "type" => "object"
    },
    "JsonSchemaResponseFormat" => %{
      "properties" => %{
        "description" => %{
          "anyOf" => [
            %{
              "type" => "string"
            },
            %{
              "type" => "null"
            }
          ]
        },
        "name" => %{
          "type" => "string"
        },
        "schema" => %{
          "anyOf" => [
            %{
              "type" => "null"
            }
          ]
        },
        "strict" => %{
          "type" => "boolean"
        },
        "type" => %{
          "enum" => [
            "json_schema"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "name",
        "description",
        "schema",
        "strict"
      ],
      "type" => "object"
    },
    "LogProb" => %{
      "properties" => %{
        "bytes" => %{
          "items" => %{
            "type" => "integer"
          },
          "type" => "array"
        },
        "logprob" => %{
          "type" => "number"
        },
        "token" => %{
          "type" => "string"
        },
        "top_logprobs" => %{
          "items" => %{
            "$ref" => "TopLogProb"
          },
          "type" => "array"
        }
      },
      "required" => [
        "token",
        "logprob",
        "bytes",
        "top_logprobs"
      ],
      "type" => "object"
    },
    "Message" => %{
      "properties" => %{
        "content" => %{
          "items" => %{
            "oneOf" => [
              %{
                "$ref" => "InputTextContent"
              },
              %{
                "$ref" => "OutputTextContent"
              },
              %{
                "$ref" => "TextContent"
              },
              %{
                "$ref" => "SummaryTextContent"
              },
              %{
                "$ref" => "ReasoningTextContent"
              },
              %{
                "$ref" => "RefusalContent"
              },
              %{
                "$ref" => "InputImageContent"
              },
              %{
                "$ref" => "InputFileContent"
              },
              %{
                "$ref" => "InputVideoContent"
              }
            ],
            "x-pixir-discriminator" => %{
              "index" => %{
                "input_file" => 7,
                "input_image" => 6,
                "input_text" => 0,
                "input_video" => 8,
                "output_text" => 1,
                "reasoning_text" => 4,
                "refusal" => 5,
                "summary_text" => 3,
                "text" => 2
              },
              "property" => "type"
            }
          },
          "type" => "array"
        },
        "id" => %{
          "type" => "string"
        },
        "phase" => %{
          "enum" => [
            "commentary",
            "final_answer"
          ],
          "type" => "string"
        },
        "role" => %{
          "allOf" => [
            %{
              "$ref" => "MessageRole"
            },
            %{}
          ]
        },
        "status" => %{
          "allOf" => [
            %{
              "$ref" => "MessageStatus"
            },
            %{}
          ]
        },
        "type" => %{
          "enum" => [
            "message"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "id",
        "status",
        "role",
        "content"
      ],
      "type" => "object"
    },
    "MessageRole" => %{
      "enum" => [
        "user",
        "assistant",
        "system",
        "developer"
      ],
      "type" => "string"
    },
    "MessageStatus" => %{
      "enum" => [
        "in_progress",
        "completed",
        "incomplete"
      ],
      "type" => "string"
    },
    "OutputTextContent" => %{
      "properties" => %{
        "annotations" => %{
          "items" => %{
            "$ref" => "Annotation"
          },
          "type" => "array"
        },
        "logprobs" => %{
          "items" => %{
            "$ref" => "LogProb"
          },
          "type" => "array"
        },
        "text" => %{
          "type" => "string"
        },
        "type" => %{
          "enum" => [
            "output_text"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "text",
        "annotations"
      ],
      "type" => "object"
    },
    "OutputTokensDetails" => %{
      "properties" => %{
        "reasoning_tokens" => %{
          "type" => "integer"
        }
      },
      "required" => [
        "reasoning_tokens"
      ],
      "type" => "object"
    },
    "Reasoning" => %{
      "properties" => %{
        "effort" => %{
          "anyOf" => [
            %{
              "oneOf" => [
                %{
                  "$ref" => "ReasoningEffortEnum"
                }
              ]
            },
            %{
              "type" => "null"
            }
          ]
        },
        "summary" => %{
          "anyOf" => [
            %{
              "allOf" => [
                %{
                  "$ref" => "ReasoningSummaryEnum"
                },
                %{}
              ]
            },
            %{
              "type" => "null"
            }
          ]
        }
      },
      "required" => [
        "effort",
        "summary"
      ],
      "type" => "object"
    },
    "ReasoningBody" => %{
      "properties" => %{
        "content" => %{
          "items" => %{
            "oneOf" => [
              %{
                "$ref" => "InputTextContent"
              },
              %{
                "$ref" => "OutputTextContent"
              },
              %{
                "$ref" => "TextContent"
              },
              %{
                "$ref" => "SummaryTextContent"
              },
              %{
                "$ref" => "ReasoningTextContent"
              },
              %{
                "$ref" => "RefusalContent"
              },
              %{
                "$ref" => "InputImageContent"
              },
              %{
                "$ref" => "InputFileContent"
              }
            ],
            "x-pixir-discriminator" => %{
              "index" => %{
                "input_file" => 7,
                "input_image" => 6,
                "input_text" => 0,
                "output_text" => 1,
                "reasoning_text" => 4,
                "refusal" => 5,
                "summary_text" => 3,
                "text" => 2
              },
              "property" => "type"
            }
          },
          "type" => "array"
        },
        "encrypted_content" => %{
          "type" => "string"
        },
        "id" => %{
          "type" => "string"
        },
        "summary" => %{
          "items" => %{
            "oneOf" => [
              %{
                "$ref" => "InputTextContent"
              },
              %{
                "$ref" => "OutputTextContent"
              },
              %{
                "$ref" => "TextContent"
              },
              %{
                "$ref" => "SummaryTextContent"
              },
              %{
                "$ref" => "ReasoningTextContent"
              },
              %{
                "$ref" => "RefusalContent"
              },
              %{
                "$ref" => "InputImageContent"
              },
              %{
                "$ref" => "InputFileContent"
              }
            ],
            "x-pixir-discriminator" => %{
              "index" => %{
                "input_file" => 7,
                "input_image" => 6,
                "input_text" => 0,
                "output_text" => 1,
                "reasoning_text" => 4,
                "refusal" => 5,
                "summary_text" => 3,
                "text" => 2
              },
              "property" => "type"
            }
          },
          "type" => "array"
        },
        "type" => %{
          "enum" => [
            "reasoning"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "id",
        "summary"
      ],
      "type" => "object"
    },
    "ReasoningEffortEnum" => %{
      "enum" => [
        "none",
        "low",
        "medium",
        "high",
        "xhigh"
      ],
      "type" => "string"
    },
    "ReasoningSummaryEnum" => %{
      "enum" => [
        "concise",
        "detailed",
        "auto"
      ],
      "type" => "string"
    },
    "ReasoningTextContent" => %{
      "properties" => %{
        "text" => %{
          "type" => "string"
        },
        "type" => %{
          "enum" => [
            "reasoning_text"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "text"
      ],
      "type" => "object"
    },
    "RefusalContent" => %{
      "properties" => %{
        "refusal" => %{
          "type" => "string"
        },
        "type" => %{
          "enum" => [
            "refusal"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "refusal"
      ],
      "type" => "object"
    },
    "ResponseCompletedStreamingEvent" => %{
      "properties" => %{
        "response" => %{
          "allOf" => [
            %{
              "$ref" => "ResponseResource"
            },
            %{}
          ]
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.completed"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "response"
      ],
      "type" => "object"
    },
    "ResponseContentPartAddedStreamingEvent" => %{
      "properties" => %{
        "content_index" => %{
          "type" => "integer"
        },
        "item_id" => %{
          "type" => "string"
        },
        "output_index" => %{
          "type" => "integer"
        },
        "part" => %{
          "oneOf" => [
            %{
              "$ref" => "InputTextContent"
            },
            %{
              "$ref" => "OutputTextContent"
            },
            %{
              "$ref" => "TextContent"
            },
            %{
              "$ref" => "SummaryTextContent"
            },
            %{
              "$ref" => "ReasoningTextContent"
            },
            %{
              "$ref" => "RefusalContent"
            },
            %{
              "$ref" => "InputImageContent"
            },
            %{
              "$ref" => "InputFileContent"
            }
          ],
          "x-pixir-discriminator" => %{
            "index" => %{
              "input_file" => 7,
              "input_image" => 6,
              "input_text" => 0,
              "output_text" => 1,
              "reasoning_text" => 4,
              "refusal" => 5,
              "summary_text" => 3,
              "text" => 2
            },
            "property" => "type"
          }
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.content_part.added"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "item_id",
        "output_index",
        "content_index",
        "part"
      ],
      "type" => "object"
    },
    "ResponseContentPartDoneStreamingEvent" => %{
      "properties" => %{
        "content_index" => %{
          "type" => "integer"
        },
        "item_id" => %{
          "type" => "string"
        },
        "output_index" => %{
          "type" => "integer"
        },
        "part" => %{
          "oneOf" => [
            %{
              "$ref" => "InputTextContent"
            },
            %{
              "$ref" => "OutputTextContent"
            },
            %{
              "$ref" => "TextContent"
            },
            %{
              "$ref" => "SummaryTextContent"
            },
            %{
              "$ref" => "ReasoningTextContent"
            },
            %{
              "$ref" => "RefusalContent"
            },
            %{
              "$ref" => "InputImageContent"
            },
            %{
              "$ref" => "InputFileContent"
            }
          ],
          "x-pixir-discriminator" => %{
            "index" => %{
              "input_file" => 7,
              "input_image" => 6,
              "input_text" => 0,
              "output_text" => 1,
              "reasoning_text" => 4,
              "refusal" => 5,
              "summary_text" => 3,
              "text" => 2
            },
            "property" => "type"
          }
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.content_part.done"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "item_id",
        "output_index",
        "content_index",
        "part"
      ],
      "type" => "object"
    },
    "ResponseCreatedStreamingEvent" => %{
      "properties" => %{
        "response" => %{
          "allOf" => [
            %{
              "$ref" => "ResponseResource"
            },
            %{}
          ]
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.created"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "response"
      ],
      "type" => "object"
    },
    "ResponseFailedStreamingEvent" => %{
      "properties" => %{
        "response" => %{
          "allOf" => [
            %{
              "$ref" => "ResponseResource"
            },
            %{}
          ]
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.failed"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "response"
      ],
      "type" => "object"
    },
    "ResponseFunctionCallArgumentsDeltaStreamingEvent" => %{
      "properties" => %{
        "delta" => %{
          "type" => "string"
        },
        "item_id" => %{
          "type" => "string"
        },
        "obfuscation" => %{
          "type" => "string"
        },
        "output_index" => %{
          "type" => "integer"
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.function_call_arguments.delta"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "item_id",
        "output_index",
        "delta"
      ],
      "type" => "object"
    },
    "ResponseFunctionCallArgumentsDoneStreamingEvent" => %{
      "properties" => %{
        "arguments" => %{
          "type" => "string"
        },
        "item_id" => %{
          "type" => "string"
        },
        "output_index" => %{
          "type" => "integer"
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.function_call_arguments.done"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "item_id",
        "output_index",
        "arguments"
      ],
      "type" => "object"
    },
    "ResponseInProgressStreamingEvent" => %{
      "properties" => %{
        "response" => %{
          "allOf" => [
            %{
              "$ref" => "ResponseResource"
            },
            %{}
          ]
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.in_progress"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "response"
      ],
      "type" => "object"
    },
    "ResponseIncompleteStreamingEvent" => %{
      "properties" => %{
        "response" => %{
          "allOf" => [
            %{
              "$ref" => "ResponseResource"
            },
            %{}
          ]
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.incomplete"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "response"
      ],
      "type" => "object"
    },
    "ResponseOutputItemAddedStreamingEvent" => %{
      "properties" => %{
        "item" => %{
          "anyOf" => [
            %{
              "allOf" => [
                %{
                  "$ref" => "ItemField"
                },
                %{}
              ]
            },
            %{
              "type" => "null"
            }
          ]
        },
        "output_index" => %{
          "type" => "integer"
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.output_item.added"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "output_index",
        "item"
      ],
      "type" => "object"
    },
    "ResponseOutputItemDoneStreamingEvent" => %{
      "properties" => %{
        "item" => %{
          "anyOf" => [
            %{
              "allOf" => [
                %{
                  "$ref" => "ItemField"
                },
                %{}
              ]
            },
            %{
              "type" => "null"
            }
          ]
        },
        "output_index" => %{
          "type" => "integer"
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.output_item.done"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "output_index",
        "item"
      ],
      "type" => "object"
    },
    "ResponseOutputTextAnnotationAddedStreamingEvent" => %{
      "properties" => %{
        "annotation" => %{
          "anyOf" => [
            %{
              "allOf" => [
                %{
                  "$ref" => "Annotation"
                },
                %{}
              ]
            },
            %{
              "type" => "null"
            }
          ]
        },
        "annotation_index" => %{
          "type" => "integer"
        },
        "content_index" => %{
          "type" => "integer"
        },
        "item_id" => %{
          "type" => "string"
        },
        "output_index" => %{
          "type" => "integer"
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.output_text.annotation.added"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "item_id",
        "output_index",
        "content_index",
        "annotation_index",
        "annotation"
      ],
      "type" => "object"
    },
    "ResponseOutputTextDeltaStreamingEvent" => %{
      "properties" => %{
        "content_index" => %{
          "type" => "integer"
        },
        "delta" => %{
          "type" => "string"
        },
        "item_id" => %{
          "type" => "string"
        },
        "logprobs" => %{
          "items" => %{
            "$ref" => "LogProb"
          },
          "type" => "array"
        },
        "obfuscation" => %{
          "type" => "string"
        },
        "output_index" => %{
          "type" => "integer"
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.output_text.delta"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "item_id",
        "output_index",
        "content_index",
        "delta"
      ],
      "type" => "object"
    },
    "ResponseOutputTextDoneStreamingEvent" => %{
      "properties" => %{
        "content_index" => %{
          "type" => "integer"
        },
        "item_id" => %{
          "type" => "string"
        },
        "logprobs" => %{
          "items" => %{
            "$ref" => "LogProb"
          },
          "type" => "array"
        },
        "output_index" => %{
          "type" => "integer"
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "text" => %{
          "type" => "string"
        },
        "type" => %{
          "enum" => [
            "response.output_text.done"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "item_id",
        "output_index",
        "content_index",
        "text"
      ],
      "type" => "object"
    },
    "ResponseQueuedStreamingEvent" => %{
      "properties" => %{
        "response" => %{
          "allOf" => [
            %{
              "$ref" => "ResponseResource"
            },
            %{}
          ]
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.queued"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "response"
      ],
      "type" => "object"
    },
    "ResponseReasoningDeltaStreamingEvent" => %{
      "properties" => %{
        "content_index" => %{
          "type" => "integer"
        },
        "delta" => %{
          "type" => "string"
        },
        "item_id" => %{
          "type" => "string"
        },
        "obfuscation" => %{
          "type" => "string"
        },
        "output_index" => %{
          "type" => "integer"
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.reasoning.delta"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "item_id",
        "output_index",
        "content_index",
        "delta"
      ],
      "type" => "object"
    },
    "ResponseReasoningDoneStreamingEvent" => %{
      "properties" => %{
        "content_index" => %{
          "type" => "integer"
        },
        "item_id" => %{
          "type" => "string"
        },
        "output_index" => %{
          "type" => "integer"
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "text" => %{
          "type" => "string"
        },
        "type" => %{
          "enum" => [
            "response.reasoning.done"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "item_id",
        "output_index",
        "content_index",
        "text"
      ],
      "type" => "object"
    },
    "ResponseReasoningSummaryDeltaStreamingEvent" => %{
      "properties" => %{
        "delta" => %{
          "type" => "string"
        },
        "item_id" => %{
          "type" => "string"
        },
        "obfuscation" => %{
          "type" => "string"
        },
        "output_index" => %{
          "type" => "integer"
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "summary_index" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.reasoning_summary_text.delta"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "item_id",
        "output_index",
        "summary_index",
        "delta"
      ],
      "type" => "object"
    },
    "ResponseReasoningSummaryDoneStreamingEvent" => %{
      "properties" => %{
        "item_id" => %{
          "type" => "string"
        },
        "output_index" => %{
          "type" => "integer"
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "summary_index" => %{
          "type" => "integer"
        },
        "text" => %{
          "type" => "string"
        },
        "type" => %{
          "enum" => [
            "response.reasoning_summary_text.done"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "item_id",
        "output_index",
        "summary_index",
        "text"
      ],
      "type" => "object"
    },
    "ResponseReasoningSummaryPartAddedStreamingEvent" => %{
      "properties" => %{
        "item_id" => %{
          "type" => "string"
        },
        "output_index" => %{
          "type" => "integer"
        },
        "part" => %{
          "oneOf" => [
            %{
              "$ref" => "InputTextContent"
            },
            %{
              "$ref" => "OutputTextContent"
            },
            %{
              "$ref" => "TextContent"
            },
            %{
              "$ref" => "SummaryTextContent"
            },
            %{
              "$ref" => "ReasoningTextContent"
            },
            %{
              "$ref" => "RefusalContent"
            },
            %{
              "$ref" => "InputImageContent"
            },
            %{
              "$ref" => "InputFileContent"
            }
          ],
          "x-pixir-discriminator" => %{
            "index" => %{
              "input_file" => 7,
              "input_image" => 6,
              "input_text" => 0,
              "output_text" => 1,
              "reasoning_text" => 4,
              "refusal" => 5,
              "summary_text" => 3,
              "text" => 2
            },
            "property" => "type"
          }
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "summary_index" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.reasoning_summary_part.added"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "item_id",
        "output_index",
        "summary_index",
        "part"
      ],
      "type" => "object"
    },
    "ResponseReasoningSummaryPartDoneStreamingEvent" => %{
      "properties" => %{
        "item_id" => %{
          "type" => "string"
        },
        "output_index" => %{
          "type" => "integer"
        },
        "part" => %{
          "oneOf" => [
            %{
              "$ref" => "InputTextContent"
            },
            %{
              "$ref" => "OutputTextContent"
            },
            %{
              "$ref" => "TextContent"
            },
            %{
              "$ref" => "SummaryTextContent"
            },
            %{
              "$ref" => "ReasoningTextContent"
            },
            %{
              "$ref" => "RefusalContent"
            },
            %{
              "$ref" => "InputImageContent"
            },
            %{
              "$ref" => "InputFileContent"
            }
          ],
          "x-pixir-discriminator" => %{
            "index" => %{
              "input_file" => 7,
              "input_image" => 6,
              "input_text" => 0,
              "output_text" => 1,
              "reasoning_text" => 4,
              "refusal" => 5,
              "summary_text" => 3,
              "text" => 2
            },
            "property" => "type"
          }
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "summary_index" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.reasoning_summary_part.done"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "item_id",
        "output_index",
        "summary_index",
        "part"
      ],
      "type" => "object"
    },
    "ResponseRefusalDeltaStreamingEvent" => %{
      "properties" => %{
        "content_index" => %{
          "type" => "integer"
        },
        "delta" => %{
          "type" => "string"
        },
        "item_id" => %{
          "type" => "string"
        },
        "output_index" => %{
          "type" => "integer"
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.refusal.delta"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "item_id",
        "output_index",
        "content_index",
        "delta"
      ],
      "type" => "object"
    },
    "ResponseRefusalDoneStreamingEvent" => %{
      "properties" => %{
        "content_index" => %{
          "type" => "integer"
        },
        "item_id" => %{
          "type" => "string"
        },
        "output_index" => %{
          "type" => "integer"
        },
        "refusal" => %{
          "type" => "string"
        },
        "sequence_number" => %{
          "type" => "integer"
        },
        "type" => %{
          "enum" => [
            "response.refusal.done"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "sequence_number",
        "item_id",
        "output_index",
        "content_index",
        "refusal"
      ],
      "type" => "object"
    },
    "ResponseResource" => %{
      "properties" => %{
        "background" => %{
          "type" => "boolean"
        },
        "completed_at" => %{
          "anyOf" => [
            %{
              "type" => "integer"
            },
            %{
              "type" => "null"
            }
          ]
        },
        "created_at" => %{
          "type" => "integer"
        },
        "error" => %{
          "anyOf" => [
            %{
              "allOf" => [
                %{
                  "$ref" => "Error"
                },
                %{}
              ]
            },
            %{
              "type" => "null"
            }
          ]
        },
        "frequency_penalty" => %{
          "type" => "number"
        },
        "id" => %{
          "type" => "string"
        },
        "incomplete_details" => %{
          "anyOf" => [
            %{
              "allOf" => [
                %{
                  "$ref" => "IncompleteDetails"
                },
                %{}
              ]
            },
            %{
              "type" => "null"
            }
          ]
        },
        "instructions" => %{
          "anyOf" => [
            %{
              "oneOf" => [
                %{
                  "type" => "string"
                }
              ]
            },
            %{
              "type" => "null"
            }
          ]
        },
        "max_output_tokens" => %{
          "anyOf" => [
            %{
              "type" => "integer"
            },
            %{
              "type" => "null"
            }
          ]
        },
        "max_tool_calls" => %{
          "anyOf" => [
            %{
              "type" => "integer"
            },
            %{
              "type" => "null"
            }
          ]
        },
        "metadata" => %{},
        "model" => %{
          "type" => "string"
        },
        "object" => %{
          "enum" => [
            "response"
          ],
          "type" => "string"
        },
        "output" => %{
          "items" => %{
            "$ref" => "ItemField"
          },
          "type" => "array"
        },
        "parallel_tool_calls" => %{
          "type" => "boolean"
        },
        "presence_penalty" => %{
          "type" => "number"
        },
        "previous_response_id" => %{
          "anyOf" => [
            %{
              "type" => "string"
            },
            %{
              "type" => "null"
            }
          ]
        },
        "prompt_cache_key" => %{
          "anyOf" => [
            %{
              "type" => "string"
            },
            %{
              "type" => "null"
            }
          ]
        },
        "reasoning" => %{
          "anyOf" => [
            %{
              "allOf" => [
                %{
                  "$ref" => "Reasoning"
                },
                %{}
              ]
            },
            %{
              "type" => "null"
            }
          ]
        },
        "safety_identifier" => %{
          "anyOf" => [
            %{
              "type" => "string"
            },
            %{
              "type" => "null"
            }
          ]
        },
        "service_tier" => %{
          "type" => "string"
        },
        "status" => %{
          "type" => "string"
        },
        "store" => %{
          "type" => "boolean"
        },
        "temperature" => %{
          "type" => "number"
        },
        "text" => %{
          "allOf" => [
            %{
              "$ref" => "TextField"
            },
            %{}
          ]
        },
        "tool_choice" => %{
          "oneOf" => [
            %{
              "$ref" => "FunctionToolChoice"
            },
            %{
              "$ref" => "ToolChoiceValueEnum"
            },
            %{
              "$ref" => "AllowedToolChoice"
            }
          ]
        },
        "tools" => %{
          "items" => %{
            "$ref" => "Tool"
          },
          "type" => "array"
        },
        "top_logprobs" => %{
          "type" => "integer"
        },
        "top_p" => %{
          "type" => "number"
        },
        "truncation" => %{
          "allOf" => [
            %{
              "$ref" => "TruncationEnum"
            },
            %{}
          ]
        },
        "usage" => %{
          "anyOf" => [
            %{
              "allOf" => [
                %{
                  "$ref" => "Usage"
                },
                %{}
              ]
            },
            %{
              "type" => "null"
            }
          ]
        }
      },
      "required" => [
        "id",
        "object",
        "created_at",
        "completed_at",
        "status",
        "incomplete_details",
        "model",
        "previous_response_id",
        "instructions",
        "output",
        "error",
        "tools",
        "tool_choice",
        "truncation",
        "parallel_tool_calls",
        "text",
        "top_p",
        "presence_penalty",
        "frequency_penalty",
        "top_logprobs",
        "temperature",
        "reasoning",
        "usage",
        "max_output_tokens",
        "max_tool_calls",
        "store",
        "background",
        "service_tier",
        "metadata",
        "safety_identifier",
        "prompt_cache_key"
      ],
      "type" => "object"
    },
    "SummaryTextContent" => %{
      "properties" => %{
        "text" => %{
          "type" => "string"
        },
        "type" => %{
          "enum" => [
            "summary_text"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "text"
      ],
      "type" => "object"
    },
    "TextContent" => %{
      "properties" => %{
        "text" => %{
          "type" => "string"
        },
        "type" => %{
          "enum" => [
            "text"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "text"
      ],
      "type" => "object"
    },
    "TextField" => %{
      "properties" => %{
        "format" => %{
          "oneOf" => [
            %{
              "$ref" => "TextResponseFormat"
            },
            %{
              "$ref" => "JsonObjectResponseFormat"
            },
            %{
              "$ref" => "JsonSchemaResponseFormat"
            }
          ]
        },
        "verbosity" => %{
          "$ref" => "VerbosityEnum"
        }
      },
      "required" => [
        "format"
      ],
      "type" => "object"
    },
    "TextResponseFormat" => %{
      "properties" => %{
        "type" => %{
          "enum" => [
            "text"
          ],
          "type" => "string"
        }
      },
      "required" => [
        "type"
      ],
      "type" => "object"
    },
    "Tool" => %{
      "oneOf" => [
        %{
          "$ref" => "FunctionTool"
        }
      ],
      "x-pixir-discriminator" => %{
        "index" => %{
          "function" => 0
        },
        "property" => "type"
      }
    },
    "ToolChoiceValueEnum" => %{
      "enum" => [
        "none",
        "auto",
        "required"
      ],
      "type" => "string"
    },
    "TopLogProb" => %{
      "properties" => %{
        "bytes" => %{
          "items" => %{
            "type" => "integer"
          },
          "type" => "array"
        },
        "logprob" => %{
          "type" => "number"
        },
        "token" => %{
          "type" => "string"
        }
      },
      "required" => [
        "token",
        "logprob",
        "bytes"
      ],
      "type" => "object"
    },
    "TruncationEnum" => %{
      "enum" => [
        "auto",
        "disabled"
      ],
      "type" => "string"
    },
    "UrlCitationBody" => %{
      "properties" => %{
        "end_index" => %{
          "type" => "integer"
        },
        "start_index" => %{
          "type" => "integer"
        },
        "title" => %{
          "type" => "string"
        },
        "type" => %{
          "enum" => [
            "url_citation"
          ],
          "type" => "string"
        },
        "url" => %{
          "type" => "string"
        }
      },
      "required" => [
        "type",
        "url",
        "start_index",
        "end_index",
        "title"
      ],
      "type" => "object"
    },
    "Usage" => %{
      "properties" => %{
        "input_tokens" => %{
          "type" => "integer"
        },
        "input_tokens_details" => %{
          "allOf" => [
            %{
              "$ref" => "InputTokensDetails"
            },
            %{}
          ]
        },
        "output_tokens" => %{
          "type" => "integer"
        },
        "output_tokens_details" => %{
          "allOf" => [
            %{
              "$ref" => "OutputTokensDetails"
            },
            %{}
          ]
        },
        "total_tokens" => %{
          "type" => "integer"
        }
      },
      "required" => [
        "input_tokens",
        "output_tokens",
        "total_tokens",
        "input_tokens_details",
        "output_tokens_details"
      ],
      "type" => "object"
    },
    "VerbosityEnum" => %{
      "enum" => [
        "low",
        "medium",
        "high"
      ],
      "type" => "string"
    }
  }
  @manifest %{
    "annotation_keywords" => [
      "default",
      "description",
      "discriminator",
      "example",
      "title",
      "x-enumDescriptions"
    ],
    "authority" => %{
      "commit" => "cd31bc2060a27ee87a05ec97f49c84027eb6c3ba",
      "openapi_blob" => "f8a773dd0a754d01975d6730af4f8ec50b63d593",
      "openapi_sha256" => "b445f548d7d13da7768c06cab4317c59928a46a35847d4a515b94c75b8294c87",
      "repository" => "openresponses/openresponses",
      "tree" => "d9c5969e195f1b1b8cd57df37f51e88079ed28ab"
    },
    "corpus" => %{
      "bases_path" => "schema_corpus_bases.json",
      "counts" => %{
        "ignored-safe" => 289,
        "invalid" => 12588,
        "local-limit" => 47,
        "portable" => 443,
        "unsupported" => 868
      },
      "coverage" => %{
        "array_branches" => %{
          "expected" => 132,
          "observed" => 132
        },
        "expected_token_count" => 1996,
        "expected_token_sha256" =>
          "3a445907ddd5566be190439728e856d03009ff1dbe739eb949f2d33887150657",
        "json_incompatible_kinds" => %{
          "expected" => %{
            "array" => 185,
            "boolean" => 193,
            "integer" => 163,
            "null" => 197,
            "number" => 193,
            "object" => 140,
            "string" => 112
          },
          "observed" => %{
            "array" => 185,
            "boolean" => 193,
            "integer" => 163,
            "null" => 197,
            "number" => 193,
            "object" => 140,
            "string" => 112
          }
        },
        "json_integer_representations" => %{
          "expected" => %{
            "integral_float" => 30,
            "negative_zero" => 30
          },
          "observed" => %{
            "integral_float" => 30,
            "negative_zero" => 30
          }
        },
        "missing_token_count" => 0,
        "observed_token_count" => 1996,
        "observed_token_sha256" =>
          "3a445907ddd5566be190439728e856d03009ff1dbe739eb949f2d33887150657",
        "response_wrapper_equal" => true,
        "response_wrapper_fanout" => %{
          "response.completed" => 1653,
          "response.created" => 1653,
          "response.failed" => 1653,
          "response.in_progress" => 1653,
          "response.incomplete" => 1653,
          "response.queued" => 1653
        },
        "schema_families" => %{
          "expected" => 69,
          "missing" => [],
          "observed" => 69
        },
        "union_branches" => %{
          "anyOf_expected" => 45,
          "anyOf_observed" => 45,
          "oneOf_expected" => 38,
          "oneOf_observed" => 38
        }
      },
      "encoding" => "base-event-recipe-v1",
      "oracle" => "jsonschema Draft 2020-12 via bin/verify-open-responses-schema-corpus",
      "row_count" => 14235,
      "zero_conditions" => %{
        "duplicate_expanded_identity_rows" => 0,
        "invalid_full_task_success_artifacts" => 0,
        "openapi_invalid_accepted" => 0,
        "rows_without_exactly_one_disposition" => 0,
        "unallowlisted_openapi_valid_rejections" => 0
      }
    },
    "digests" => %{
      "canonical_subset_sha256" =>
        "51efcd4dbda82362587c2a45bab9b075a2c18c1a074868bb810e13d2d947e87a",
      "corpus_bases_sha256" => "add8d9a8eeb347b42d5028798a070448e6ad0615873ccd0249610a9f84a28df3",
      "corpus_sha256" => "d59da37189f085d2c7e51a3b0dc5f82311b2d8a643bf17ab76fda7acd2e6ec8f",
      "expanded_corpus_sha256" =>
        "9086178b3da309c81c5442b1370675c7ca1cb7850cd53b79d0e28902ac7ca761",
      "local_allowlist_sha256" =>
        "18c34d09474d8bf23babe8ea92bacb251cbc610e3109bbd1c1f66b9f3f6cf8f8"
    },
    "limits" => %{
      "max_depth" => 64,
      "max_evaluations" => 250_000
    },
    "local_allowlist" => [
      "event.sequence_number:nonnegative_integer",
      "event.output_index:nonnegative_integer",
      "event.content_index:nonnegative_integer",
      "event.item_id:nonempty_string",
      "Message.id:nonempty_string",
      "FunctionCall.id:nonempty_string",
      "FunctionCall.call_id:nonempty_string",
      "FunctionCall.name:nonempty_string"
    ],
    "reachable_schema_count" => 69,
    "reachable_schemas" => [
      "AllowedToolChoice",
      "Annotation",
      "CompactionBody",
      "Error",
      "ErrorPayload",
      "ErrorStreamingEvent",
      "FunctionCall",
      "FunctionCallOutput",
      "FunctionCallOutputStatusEnum",
      "FunctionCallStatus",
      "FunctionTool",
      "FunctionToolChoice",
      "ImageDetail",
      "IncompleteDetails",
      "InputFileContent",
      "InputImageContent",
      "InputTextContent",
      "InputTokensDetails",
      "InputVideoContent",
      "ItemField",
      "JsonObjectResponseFormat",
      "JsonSchemaResponseFormat",
      "LogProb",
      "Message",
      "MessageRole",
      "MessageStatus",
      "OutputTextContent",
      "OutputTokensDetails",
      "Reasoning",
      "ReasoningBody",
      "ReasoningEffortEnum",
      "ReasoningSummaryEnum",
      "ReasoningTextContent",
      "RefusalContent",
      "ResponseCompletedStreamingEvent",
      "ResponseContentPartAddedStreamingEvent",
      "ResponseContentPartDoneStreamingEvent",
      "ResponseCreatedStreamingEvent",
      "ResponseFailedStreamingEvent",
      "ResponseFunctionCallArgumentsDeltaStreamingEvent",
      "ResponseFunctionCallArgumentsDoneStreamingEvent",
      "ResponseInProgressStreamingEvent",
      "ResponseIncompleteStreamingEvent",
      "ResponseOutputItemAddedStreamingEvent",
      "ResponseOutputItemDoneStreamingEvent",
      "ResponseOutputTextAnnotationAddedStreamingEvent",
      "ResponseOutputTextDeltaStreamingEvent",
      "ResponseOutputTextDoneStreamingEvent",
      "ResponseQueuedStreamingEvent",
      "ResponseReasoningDeltaStreamingEvent",
      "ResponseReasoningDoneStreamingEvent",
      "ResponseReasoningSummaryDeltaStreamingEvent",
      "ResponseReasoningSummaryDoneStreamingEvent",
      "ResponseReasoningSummaryPartAddedStreamingEvent",
      "ResponseReasoningSummaryPartDoneStreamingEvent",
      "ResponseRefusalDeltaStreamingEvent",
      "ResponseRefusalDoneStreamingEvent",
      "ResponseResource",
      "SummaryTextContent",
      "TextContent",
      "TextField",
      "TextResponseFormat",
      "Tool",
      "ToolChoiceValueEnum",
      "TopLogProb",
      "TruncationEnum",
      "UrlCitationBody",
      "Usage",
      "VerbosityEnum"
    ],
    "response_resource_required_properties" => [
      "background",
      "completed_at",
      "created_at",
      "error",
      "frequency_penalty",
      "id",
      "incomplete_details",
      "instructions",
      "max_output_tokens",
      "max_tool_calls",
      "metadata",
      "model",
      "object",
      "output",
      "parallel_tool_calls",
      "presence_penalty",
      "previous_response_id",
      "prompt_cache_key",
      "reasoning",
      "safety_identifier",
      "service_tier",
      "status",
      "store",
      "temperature",
      "text",
      "tool_choice",
      "tools",
      "top_logprobs",
      "top_p",
      "truncation",
      "usage"
    ],
    "response_resource_required_property_count" => 31,
    "root_count" => 24,
    "roots" => %{
      "error" => "ErrorStreamingEvent",
      "response.completed" => "ResponseCompletedStreamingEvent",
      "response.content_part.added" => "ResponseContentPartAddedStreamingEvent",
      "response.content_part.done" => "ResponseContentPartDoneStreamingEvent",
      "response.created" => "ResponseCreatedStreamingEvent",
      "response.failed" => "ResponseFailedStreamingEvent",
      "response.function_call_arguments.delta" =>
        "ResponseFunctionCallArgumentsDeltaStreamingEvent",
      "response.function_call_arguments.done" =>
        "ResponseFunctionCallArgumentsDoneStreamingEvent",
      "response.in_progress" => "ResponseInProgressStreamingEvent",
      "response.incomplete" => "ResponseIncompleteStreamingEvent",
      "response.output_item.added" => "ResponseOutputItemAddedStreamingEvent",
      "response.output_item.done" => "ResponseOutputItemDoneStreamingEvent",
      "response.output_text.annotation.added" =>
        "ResponseOutputTextAnnotationAddedStreamingEvent",
      "response.output_text.delta" => "ResponseOutputTextDeltaStreamingEvent",
      "response.output_text.done" => "ResponseOutputTextDoneStreamingEvent",
      "response.queued" => "ResponseQueuedStreamingEvent",
      "response.reasoning.delta" => "ResponseReasoningDeltaStreamingEvent",
      "response.reasoning.done" => "ResponseReasoningDoneStreamingEvent",
      "response.reasoning_summary_part.added" =>
        "ResponseReasoningSummaryPartAddedStreamingEvent",
      "response.reasoning_summary_part.done" => "ResponseReasoningSummaryPartDoneStreamingEvent",
      "response.reasoning_summary_text.delta" => "ResponseReasoningSummaryDeltaStreamingEvent",
      "response.reasoning_summary_text.done" => "ResponseReasoningSummaryDoneStreamingEvent",
      "response.refusal.delta" => "ResponseRefusalDeltaStreamingEvent",
      "response.refusal.done" => "ResponseRefusalDoneStreamingEvent"
    },
    "schema_version" => 1,
    "validation_keywords" => [
      "$ref",
      "additionalProperties",
      "allOf",
      "anyOf",
      "enum",
      "items",
      "oneOf",
      "properties",
      "required",
      "type"
    ]
  }

  @doc "Return the generated root schema name for one known HTTP/SSE event type."
  @spec event_root(String.t()) :: {:ok, String.t()} | :error
  def event_root(type) when is_binary(type), do: Map.fetch(@event_roots, type)
  def event_root(_type), do: :error

  @doc "Return one generated local schema by normalized component name."
  @spec schema(String.t()) :: {:ok, map()} | :error
  def schema(name) when is_binary(name), do: Map.fetch(@schemas, name)
  def schema(_name), do: :error

  @doc "Return fixed authority, closure, budget, and digest metadata."
  @spec manifest() :: map()
  def manifest, do: @manifest

  @doc "Return the sorted known event types compiled into this pin."
  @spec known_event_types() :: [String.t()]
  def known_event_types,
    do: [
      "error",
      "response.completed",
      "response.content_part.added",
      "response.content_part.done",
      "response.created",
      "response.failed",
      "response.function_call_arguments.delta",
      "response.function_call_arguments.done",
      "response.in_progress",
      "response.incomplete",
      "response.output_item.added",
      "response.output_item.done",
      "response.output_text.annotation.added",
      "response.output_text.delta",
      "response.output_text.done",
      "response.queued",
      "response.reasoning.delta",
      "response.reasoning.done",
      "response.reasoning_summary_part.added",
      "response.reasoning_summary_part.done",
      "response.reasoning_summary_text.delta",
      "response.reasoning_summary_text.done",
      "response.refusal.delta",
      "response.refusal.done"
    ]
end
