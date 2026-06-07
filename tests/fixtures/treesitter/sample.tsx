import React from "react";

export interface Props {
  label: string;
}

export function App(): JSX.Element {
  return <div className="app">hello</div>;
}

export const Button = (props: Props) => <button>{props.label}</button>;

export class Panel extends React.Component<Props> {
  render(): JSX.Element {
    return <span>{this.props.label}</span>;
  }
}
